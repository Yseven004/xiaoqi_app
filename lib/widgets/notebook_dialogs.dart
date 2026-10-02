import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as image;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../config/notebook_theme.dart';
import '../models/notebook.dart';
import '../services/database_service.dart';
import 'app_toast.dart';
import 'notebook_cover.dart';

typedef NotebookChanged = Future<void> Function();

Future<Notebook?> showNotebookEditor(
  BuildContext context, {
  Notebook? notebook,
  DatabaseService? database,
}) {
  return showModalBottomSheet<Notebook>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    backgroundColor: NotebookTheme.lightSurface,
    builder: (_) => _NotebookEditorSheet(
      notebook: notebook,
      database: database ?? DatabaseService(),
    ),
  );
}

Future<void> showNotebookActions(
  BuildContext context, {
  required Notebook notebook,
  NotebookChanged? onChanged,
  DatabaseService? database,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: NotebookTheme.lightSurface,
    builder: (_) => _NotebookActionSheet(
      rootContext: context,
      initialNotebook: notebook,
      database: database ?? DatabaseService(),
      onChanged: onChanged,
    ),
  );
}

class _NotebookEditorSheet extends StatefulWidget {
  const _NotebookEditorSheet({required this.notebook, required this.database});

  final Notebook? notebook;
  final DatabaseService database;

  @override
  State<_NotebookEditorSheet> createState() => _NotebookEditorSheetState();
}

class _NotebookEditorSheetState extends State<_NotebookEditorSheet> {
  final _nameFocus = FocusNode();
  final _picker = ImagePicker();
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _description;
  late int _coverIndex;
  late bool _showOnHome;
  bool _dirty = false;
  bool _saving = false;
  bool _processingCover = false;
  bool _allowPop = false;
  String _nameError = '';
  String _coverError = '';
  Uint8List? _pendingCoverBytes;
  bool _removeCustomCover = false;

  @override
  void initState() {
    super.initState();
    final notebook = widget.notebook;
    _name = TextEditingController(text: notebook?.name ?? '');
    _category = TextEditingController(text: notebook?.category ?? '阅读摘录');
    _description = TextEditingController(text: notebook?.description ?? '');
    _coverIndex = notebook?.coverIndex ?? 0;
    _showOnHome = notebook?.showsOnHome ?? false;
    for (final controller in [_name, _category, _description]) {
      controller.addListener(_markDirty);
    }
  }

  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
    if (_nameError.isNotEmpty && _name.text.trim().isNotEmpty) {
      setState(() => _nameError = '');
    }
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      setState(() => _allowPop = true);
      if (mounted) Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃未保存的内容？'),
        content: const Text('名称、描述或封面修改尚未保存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      setState(() => _allowPop = true);
      Navigator.pop(context);
    }
  }

  Future<void> _pickCover() async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    setState(() {
      _processingCover = true;
      _coverError = '';
    });
    try {
      final decoded = image.decodeImage(await picked.readAsBytes());
      if (decoded == null) throw const FormatException('无法读取这张图片');
      final longest = decoded.width > decoded.height
          ? decoded.width
          : decoded.height;
      final optimized = longest > 900
          ? image.copyResize(
              decoded,
              width: decoded.width >= decoded.height ? 900 : null,
              height: decoded.height > decoded.width ? 900 : null,
              interpolation: image.Interpolation.average,
            )
          : decoded;
      final bytes = Uint8List.fromList(image.encodeJpg(optimized, quality: 82));
      if (bytes.lengthInBytes > 950000) {
        throw const FormatException('图片仍然过大，请选择尺寸更小的封面');
      }
      if (!mounted) return;
      setState(() {
        _pendingCoverBytes = bytes;
        _removeCustomCover = false;
        _dirty = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _coverError = error is FormatException
            ? error.message
            : '封面处理失败，请换一张图片重试';
      });
    } finally {
      if (mounted) setState(() => _processingCover = false);
    }
  }

  Future<String> _persistCover() async {
    final bytes = _pendingCoverBytes;
    if (bytes == null) {
      return _removeCustomCover ? '' : widget.notebook?.coverPath ?? '';
    }
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'notebook_covers'));
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.path,
        'cover_${DateTime.now().microsecondsSinceEpoch}.jpg',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<int?> _chooseReplacement() async {
    final notebooks = await widget.database.queryHomeNotebooks();
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择要替换的首页笔记本'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: notebooks.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, index) {
              final item = notebooks[index];
              return ListTile(
                minTileHeight: 60,
                leading: SizedBox(
                  width: 34,
                  height: 44,
                  child: NotebookCover(
                    notebook: item,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                title: Text(item.name),
                subtitle: Text('首页第 ${index + 1} 本 · ${item.category}'),
                onTap: () => Navigator.pop(dialogContext, item.id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final trimmedName = _name.text.trim();
    if (trimmedName.isEmpty) {
      setState(() => _nameError = '请先给笔记本起一个名字');
      _nameFocus.requestFocus();
      return;
    }
    setState(() => _saving = true);
    String? newlySavedCover;
    try {
      final existing = widget.notebook;
      int? freeSlot;
      int? replacementId;
      if (_showOnHome && existing?.homeSlot == null) {
        freeSlot = await widget.database.firstFreeHomeSlot(
          excludingNotebookId: existing?.id,
        );
        if (freeSlot == null) {
          replacementId = await _chooseReplacement();
          if (replacementId == null) return;
        }
      }
      final coverPath = await _persistCover();
      if (_pendingCoverBytes != null) newlySavedCover = coverPath;
      int id;
      if (existing == null) {
        id = await widget.database.createNotebook(
          name: trimmedName,
          category: _category.text,
          description: _description.text,
          coverIndex: _coverIndex,
          coverPath: coverPath,
          homeSlot: freeSlot,
        );
      } else {
        id = existing.id!;
        await widget.database.updateNotebook(
          existing.copyWith(
            name: trimmedName,
            category: _category.text,
            description: _description.text,
            coverIndex: _coverIndex,
            coverPath: coverPath,
          ),
        );
        if (!_showOnHome && existing.homeSlot != null) {
          await widget.database.setNotebookHomeSlot(id, null);
        } else if (_showOnHome &&
            existing.homeSlot == null &&
            replacementId == null) {
          await widget.database.setNotebookHomeSlot(id, freeSlot);
        }
      }
      if (replacementId != null) {
        await widget.database.replaceHomeNotebook(
          incomingNotebookId: id,
          displacedNotebookId: replacementId,
        );
      }
      final oldPath = existing?.coverPath ?? '';
      if (oldPath.isNotEmpty && oldPath != coverPath) {
        try {
          final oldFile = File(oldPath);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {}
      }
      final saved = await widget.database.getNotebookById(id);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _allowPop = true;
      });
      Navigator.pop(context, saved);
    } catch (error) {
      if (newlySavedCover != null) {
        try {
          await File(newlySavedCover).delete();
        } catch (_) {}
      }
      if (mounted) AppToast.show(context, '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _category, _description]) {
      controller
        ..removeListener(_markDirty)
        ..dispose();
    }
    _nameFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.notebook;
    final preview = Notebook(
      name: _name.text.trim().isEmpty ? '新笔记本' : _name.text.trim(),
      category: _category.text,
      description: _description.text,
      coverIndex: _coverIndex,
      coverPath: _removeCustomCover ? '' : existing?.coverPath ?? '',
      createdAt: existing?.createdAt ?? '',
      updatedAt: existing?.updatedAt ?? '',
    );
    return PopScope<Object?>(
      canPop: _allowPop || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          14,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 22,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        existing == null ? '新建笔记本' : '编辑笔记本',
                        style: const TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        existing == null ? '名称必填，其余以后也可以修改' : '修改会自动同步到首页和书房',
                        style: const TextStyle(color: NotebookTheme.lightMuted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _requestClose,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('notebook_name_field'),
              controller: _name,
              focusNode: _nameFocus,
              autofocus: false,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: '名称',
                hintText: '例如：当下的力量',
                errorText: _nameError.isEmpty ? null : _nameError,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _category,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '类别',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _description,
              maxLength: 160,
              minLines: 2,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '描述',
                hintText: '写下这本笔记本准备记录什么',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              value: _showOnHome,
              contentPadding: EdgeInsets.zero,
              activeThumbColor: NotebookTheme.accent,
              title: const Text('出现在首页书架'),
              subtitle: const Text('首页最多展示 7 本'),
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                      _showOnHome = value;
                      _dirty = true;
                    }),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  height: 96,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      NotebookCover(notebook: preview),
                      if (_pendingCoverBytes != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.memory(
                            _pendingCoverBytes!,
                            fit: BoxFit.cover,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '自定义封面',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '最长边会压缩到 900px',
                        style: TextStyle(color: NotebookTheme.lightMuted),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _processingCover || _saving
                                ? null
                                : _pickCover,
                            icon: _processingCover
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.image_outlined),
                            label: const Text('选择图片'),
                          ),
                          if (_pendingCoverBytes != null ||
                              (existing?.coverPath.isNotEmpty ?? false))
                            TextButton(
                              onPressed: _saving
                                  ? null
                                  : () => setState(() {
                                      _pendingCoverBytes = null;
                                      _removeCustomCover = true;
                                      _dirty = true;
                                    }),
                              child: const Text('恢复渐变'),
                            ),
                        ],
                      ),
                      if (_coverError.isNotEmpty)
                        Text(
                          _coverError,
                          style: const TextStyle(
                            color: NotebookTheme.danger,
                            fontSize: 12,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              '封面颜色',
              style: TextStyle(
                color: NotebookTheme.lightMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: List.generate(
                NotebookTheme.covers.length,
                (index) => InkWell(
                  key: Key('notebook_cover_$index'),
                  borderRadius: BorderRadius.circular(10),
                  onTap: _saving
                      ? null
                      : () => setState(() {
                          _coverIndex = index;
                          _pendingCoverBytes = null;
                          _removeCustomCover = true;
                          _dirty = true;
                        }),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: NotebookTheme.coverGradient(index),
                      borderRadius: BorderRadius.circular(10),
                      border: _coverIndex == index
                          ? Border.all(color: NotebookTheme.lightInk, width: 3)
                          : null,
                    ),
                    child: _coverIndex == index
                        ? const Icon(Icons.check, color: Colors.white)
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const Key('save_notebook_button'),
                onPressed: _saving || _processingCover ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: NotebookTheme.accent,
                  foregroundColor: Colors.white,
                ),
                child: _saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Text(existing == null ? '创建' : '保存修改'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotebookActionSheet extends StatefulWidget {
  const _NotebookActionSheet({
    required this.rootContext,
    required this.initialNotebook,
    required this.database,
    required this.onChanged,
  });

  final BuildContext rootContext;
  final Notebook initialNotebook;
  final DatabaseService database;
  final NotebookChanged? onChanged;

  @override
  State<_NotebookActionSheet> createState() => _NotebookActionSheetState();
}

class _NotebookActionSheetState extends State<_NotebookActionSheet> {
  late Notebook _notebook = widget.initialNotebook;
  bool _busy = false;

  Future<void> _refresh() async {
    await widget.onChanged?.call();
    final id = _notebook.id;
    if (id == null || !mounted) return;
    final refreshed = await widget.database.getNotebookById(id);
    if (refreshed != null && mounted) setState(() => _notebook = refreshed);
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
      await _refresh();
    } catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<int?> _chooseReplacement() async {
    final notebooks = await widget.database.queryHomeNotebooks();
    if (!mounted) return null;
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('选择要替换的首页笔记本'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: notebooks.length,
            itemBuilder: (_, index) {
              final item = notebooks[index];
              return ListTile(
                minTileHeight: 58,
                title: Text(item.name),
                subtitle: Text('首页第 ${index + 1} 本'),
                onTap: () => Navigator.pop(dialogContext, item.id),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String label,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: NotebookTheme.danger,
                ),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(label),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _delete() async {
    final confirmed = await _confirm(
      title: '删除「${_notebook.name}」？',
      message: '删除后会移到“最近删除”保存 30 天，期间可以从书房恢复。',
      label: '删除',
    );
    if (!confirmed || !mounted) return;
    final notebookId = _notebook.id!;
    if (widget.rootContext.mounted) {
      ScaffoldMessenger.of(widget.rootContext).clearSnackBars();
    }
    Navigator.pop(context);
    await widget.database.deleteNotebook(notebookId);
    await widget.onChanged?.call();
  }

  Future<void> _permanentDelete() async {
    final confirmed = await _confirm(
      title: '永久删除「${_notebook.name}」？',
      message: '此操作无法撤销，笔记本及其中的笔记会被彻底移除。',
      label: '永久删除',
    );
    if (!confirmed || !mounted) return;
    Navigator.pop(context);
    await widget.database.permanentlyDeleteNotebook(_notebook.id!);
    await widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (_notebook.isDeleted) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionHeader(notebook: _notebook),
            ListTile(
              minTileHeight: 52,
              leading: const Icon(Icons.restore_outlined),
              title: const Text('恢复到书房'),
              enabled: !_busy,
              onTap: () async {
                Navigator.pop(context);
                await widget.database.restoreNotebook(_notebook.id!);
                await widget.onChanged?.call();
              },
            ),
            ListTile(
              minTileHeight: 52,
              leading: const Icon(
                Icons.delete_forever_outlined,
                color: NotebookTheme.danger,
              ),
              title: const Text(
                '永久删除',
                style: TextStyle(color: NotebookTheme.danger),
              ),
              enabled: !_busy,
              onTap: _permanentDelete,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ActionHeader(notebook: _notebook),
          if (!_notebook.isArchived) ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 2),
                child: Text(
                  '显示与排序',
                  style: TextStyle(
                    color: NotebookTheme.lightMuted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.push_pin_outlined),
              title: const Text('置顶'),
              subtitle: const Text('排在书房最前面'),
              value: _notebook.isPinned,
              onChanged: _busy
                  ? null
                  : (value) => _run(
                      () => widget.database.setNotebookPinned(
                        _notebook.id!,
                        value,
                      ),
                    ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.home_outlined),
              title: const Text('放到首页'),
              subtitle: const Text('出现在首页书架'),
              value: _notebook.homeSlot != null,
              onChanged: _busy
                  ? null
                  : (value) async {
                      if (!value) {
                        await _run(
                          () => widget.database.setNotebookHomeSlot(
                            _notebook.id!,
                            null,
                          ),
                        );
                        return;
                      }
                      final free = await widget.database.firstFreeHomeSlot(
                        excludingNotebookId: _notebook.id,
                      );
                      if (free != null) {
                        await _run(
                          () => widget.database.setNotebookHomeSlot(
                            _notebook.id!,
                            free,
                          ),
                        );
                        return;
                      }
                      final displaced = await _chooseReplacement();
                      if (displaced != null) {
                        await _run(
                          () => widget.database.replaceHomeNotebook(
                            incomingNotebookId: _notebook.id!,
                            displacedNotebookId: displaced,
                          ),
                        );
                      }
                    },
            ),
          ],
          const Divider(height: 1),
          ListTile(
            minTileHeight: 52,
            leading: const Icon(Icons.edit_outlined),
            title: const Text('编辑笔记本'),
            enabled: !_busy,
            onTap: () async {
              Navigator.pop(context);
              final saved = await showNotebookEditor(
                widget.rootContext,
                notebook: _notebook,
                database: widget.database,
              );
              if (saved != null) await widget.onChanged?.call();
            },
          ),
          ListTile(
            minTileHeight: 52,
            leading: const Icon(Icons.archive_outlined),
            title: Text(_notebook.isArchived ? '取消归档' : '归档'),
            enabled: !_busy,
            onTap: () async {
              Navigator.pop(context);
              await widget.database.setNotebookArchived(
                _notebook.id!,
                !_notebook.isArchived,
              );
              await widget.onChanged?.call();
            },
          ),
          const Divider(height: 1),
          ListTile(
            minTileHeight: 52,
            leading: const Icon(
              Icons.delete_outline,
              color: NotebookTheme.danger,
            ),
            title: const Text(
              '删除笔记本',
              style: TextStyle(color: NotebookTheme.danger),
            ),
            enabled: !_busy,
            onTap: _delete,
          ),
        ],
      ),
    );
  }
}

class _ActionHeader extends StatelessWidget {
  const _ActionHeader({required this.notebook});

  final Notebook notebook;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 38,
          height: 50,
          child: NotebookCover(
            notebook: notebook,
            borderRadius: BorderRadius.circular(7),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                notebook.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                notebook.isDeleted ? '最近删除' : notebook.category,
                style: const TextStyle(color: NotebookTheme.lightMuted),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}
