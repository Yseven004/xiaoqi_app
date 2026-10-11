import 'dart:async';
import '../widgets/app_toast.dart';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../config/colors.dart';
import '../models/note.dart';
import '../services/database_service.dart';
import '../services/permission_service.dart';

class PhotoNoteEditPage extends StatefulWidget {
  final String imagePath;
  final Note? existingNote;

  const PhotoNoteEditPage({
    super.key,
    required this.imagePath,
    this.existingNote,
  });

  bool get isEditMode => existingNote != null;

  @override
  State<PhotoNoteEditPage> createState() => _PhotoNoteEditPageState();
}

class _PhotoNoteEditPageState extends State<PhotoNoteEditPage>
    with TickerProviderStateMixin {
  late AnimationController _animController;

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _bookNameController = TextEditingController();
  final TextEditingController _bookPageController = TextEditingController();

  bool _isSaving = false;
  bool _showSuccess = false;
  String? _newPhotoPath;
  final DatabaseService _db = DatabaseService();
  final ImagePicker _picker = ImagePicker();
  final PermissionService _permissionService = PermissionService();

  double _animProgress = 0.0;
  late AnimationController _slideCtrl;
  late Animation<double> _slideProgress;

  bool get _isEditMode => widget.isEditMode;

  String get _displayImagePath {
    if (_newPhotoPath != null) return _newPhotoPath!;
    if (_isEditMode) return widget.existingNote!.photoPath;
    return widget.imagePath;
  }

  Future<void> _replacePhoto() async {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.camera_alt_outlined,
                    color: AppColors.accent,
                  ),
                  title: const Text('重新拍照'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _onTakeNewPhoto();
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.photo_library_outlined,
                    color: AppColors.accent,
                  ),
                  title: const Text('从相册选择'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _onPickNewPhoto();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _onTakeNewPhoto() async {
    try {
      final hasPermission = await _permissionService.requestCameraPermission();
      if (!mounted) return;
      if (!hasPermission) {
        _permissionService.showPermissionDeniedDialog(context, '相机');
        return;
      }
      final image = await _picker.pickImage(source: ImageSource.camera);
      if (image == null || !mounted) return;
      final path = await _persistPickedPhoto(image);
      if (!mounted) return;
      setState(() => _newPhotoPath = path);
      debugPrint('[XiaoQi] PhotoEdit: 更换照片 拍照=$path');
    } catch (e) {
      debugPrint('[XiaoQi] PhotoEdit: 拍照失败: $e');
      if (mounted) {
        AppToast.show(context, '拍照失败，请重试');
      }
    }
  }

  Future<void> _onPickNewPhoto() async {
    try {
      final hasPermission = await _permissionService.requestGalleryPermission();
      if (!hasPermission) {
        if (mounted) {
          _permissionService.showPermissionDeniedDialog(context, '相册');
        }
        return;
      }
      final image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null || !mounted) return;
      final path = await _persistPickedPhoto(image);
      if (!mounted) return;
      setState(() => _newPhotoPath = path);
      debugPrint('[XiaoQi] PhotoEdit: 更换照片 相册=$path');
    } catch (e) {
      debugPrint('[XiaoQi] PhotoEdit: 选图失败: $e');
      if (mounted) {
        AppToast.show(context, '选图失败，请重试');
      }
    }
  }

  Future<String> _persistPickedPhoto(XFile image) async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory(p.join(appDir.path, 'photos', 'temp'));
    await photosDir.create(recursive: true);
    final extension = p.extension(image.path).isEmpty
        ? '.jpg'
        : p.extension(image.path);
    final fileName =
        'photo_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}$extension';
    return (await File(image.path).copy(p.join(photosDir.path, fileName))).path;
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _animController.addListener(() {
      setState(() => _animProgress = _animController.value);
    });

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _slideProgress = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.elasticOut,
    );

    if (_isEditMode) {
      _animController.value = 1.0;
      _slideCtrl.forward();
      final note = widget.existingNote!;
      _titleController.text = note.title;
      _contentController.text = note.content;
      _bookNameController.text = note.bookName;
      _bookPageController.text = note.bookPage;
    } else {
      _animController.forward();
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _slideCtrl.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _bookNameController.dispose();
    _bookPageController.dispose();
    super.dispose();
  }

  void _openFullScreenImage() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.black,
          insetPadding: EdgeInsets.zero,
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 3.0,
                  child: Image.file(
                    File(widget.imagePath),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.broken_image,
                              color: AppColors.textSecondary,
                              size: 48,
                            ),
                            SizedBox(height: 8),
                            Text(
                              '图片加载失败',
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: 40,
                right: 16,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        );
      },
    ).then((_) {});
  }

  Future<void> _onSave() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      if (_isEditMode) {
        final current = await _db.getNoteById(widget.existingNote!.id!);
        if (current == null || current.isDeleted == 1) {
          if (mounted) {
            AppToast.show(context, '该笔记已被删除');
            Navigator.of(context).pop();
          }
          return;
        }

        final now = DateTime.now().toIso8601String();
        String photoPath = widget.existingNote!.photoPath;

        if (_newPhotoPath != null) {
          final newFile = File(_newPhotoPath!);
          if (await newFile.exists()) {
            final appDir = await getApplicationDocumentsDirectory();
            final photosDir = Directory(p.join(appDir.path, 'photos'));
            if (!await photosDir.exists()) {
              await photosDir.create(recursive: true);
            }
            final random = Random().nextInt(99999);
            final ts = DateTime.now().millisecondsSinceEpoch;
            final fileName = '${ts}_$random.jpg';
            final persistentPath = p.join(photosDir.path, fileName);
            await newFile.copy(persistentPath);
            photoPath = persistentPath;
            debugPrint('[XiaoQi] PhotoEdit: 新照片已保存: $persistentPath');
          }
        }

        final note = Note(
          id: widget.existingNote!.id,
          type: 'photo',
          title: _titleController.text.trim(),
          content: _contentController.text.trim(),
          photoPath: photoPath,
          bookName: _bookNameController.text.trim(),
          bookPage: _bookPageController.text.trim(),
          createdAt: widget.existingNote!.createdAt,
          updatedAt: now,
        );
        await _db.update(note);
        debugPrint('[XiaoQi] PhotoEdit: 更新笔记 id=${note.id}');

        if (!mounted) return;
        setState(() => _showSuccess = true);
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) Navigator.of(context).pop(true);
      } else {
        final tempFile = File(widget.imagePath);
        if (!await tempFile.exists()) {
          if (mounted) {
            AppToast.show(context, '图片已失效，请重新拍照');
          }
          setState(() => _isSaving = false);
          return;
        }

        final appDir = await getApplicationDocumentsDirectory();
        final photosDir = Directory(p.join(appDir.path, 'photos'));
        if (!await photosDir.exists()) {
          await photosDir.create(recursive: true);
        }

        final random = Random().nextInt(99999);
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final fileName = '${timestamp}_$random.jpg';
        final persistentPath = p.join(photosDir.path, fileName);
        await tempFile.copy(persistentPath);
        debugPrint('[XiaoQi] PhotoEdit: 图片已持久化到: $persistentPath');

        final now = DateTime.now().toIso8601String();
        final note = Note(
          type: 'photo',
          title: _titleController.text.trim(),
          content: _contentController.text.trim(),
          photoPath: persistentPath,
          bookName: _bookNameController.text.trim(),
          bookPage: _bookPageController.text.trim(),
          createdAt: now,
          updatedAt: now,
        );

        await _db.insertPhotoNote(note);
        debugPrint('[XiaoQi] PhotoEdit: 笔记保存成功');

        if (!mounted) return;
        setState(() => _showSuccess = true);
        unawaited(
          Future.delayed(const Duration(seconds: 1), () {
            if (mounted) Navigator.of(context).pop();
          }),
        );
      }
    } catch (e) {
      debugPrint('[XiaoQi] PhotoEdit: 保存失败: $e');
      setState(() => _isSaving = false);
      if (mounted) {
        AppToast.show(context, '保存失败，请重试');
      }
    }
  }

  double _shutterFlashOpacity() {
    if (_animProgress < 0.17) {
      final p = _animProgress / 0.17;
      return p < 0.5 ? p * 2 * 0.3 : (1.0 - p) * 2 * 0.3;
    }
    return 0.0;
  }

  double _photoRiseOffset(double screenHeight) {
    if (_animProgress < 0.17) return screenHeight;
    if (_animProgress >= 0.42) return 0;
    final t = (_animProgress - 0.17) / 0.25;
    final curved = Curves.easeOutCubic.transform(t);
    return screenHeight * (1.0 - curved);
  }

  double _photoScale() {
    if (_animProgress < 0.17) return 0.98;
    if (_animProgress >= 0.42) return 1.0;
    final t = (_animProgress - 0.17) / 0.25;
    final curved = Curves.easeOutCubic.transform(t);
    return 0.98 + 0.02 * curved;
  }

  double _inputOpacity() {
    if (_animProgress < 0.38) return 0.0;
    if (_animProgress >= 0.58) return 1.0;
    return (_animProgress - 0.38) / 0.20;
  }

  double _saveBtnOpacity() {
    if (_animProgress < 0.58) return 0.0;
    if (_animProgress >= 0.75) return 1.0;
    final t = (_animProgress - 0.58) / 0.17;
    return Curves.easeOut.transform(t);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom + 80;

    return PopScope(
      canPop: true,
      child: Stack(
        children: [
          Scaffold(
            backgroundColor: AppColors.background,
            resizeToAvoidBottomInset: true,
            appBar: AppBar(
              titleSpacing: 0,
              title: Text(
                _isEditMode ? '修改笔记' : '拍照笔记',
                style: const TextStyle(fontSize: 16),
              ),
              backgroundColor: AppColors.background,
              surfaceTintColor: AppColors.background,
              elevation: 0,
            ),
            body: AnimatedBuilder(
              animation: _slideProgress,
              builder: (context, child) {
                if (!_isEditMode) return child!;
                final sw = MediaQuery.of(context).size.width;
                final offset = sw * (_slideProgress.value - 1.0);
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              },
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: EdgeInsets.only(bottom: bottomPadding),
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        Transform.translate(
                          offset: Offset(0, _photoRiseOffset(screenHeight)),
                          child: Transform.scale(
                            scale: _photoScale(),
                            child: GestureDetector(
                              onTap: _isEditMode
                                  ? _replacePhoto
                                  : _openFullScreenImage,
                              child: Stack(
                                children: [
                                  Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    height: 240,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      color: AppColors.placeholder,
                                    ),
                                    clipBehavior: Clip.antiAlias,
                                    child: Image.file(
                                      File(_displayImagePath),
                                      key: ValueKey(
                                        _displayImagePath,
                                      ), // 使用路径作为 key 强制刷新
                                      gaplessPlayback: true, // 编辑完成后平滑过渡
                                      width: double.infinity,
                                      height: 240,
                                      fit: BoxFit.cover,
                                      cacheWidth: 640,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                            return const Center(
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(
                                                    Icons.broken_image,
                                                    color:
                                                        AppColors.textSecondary,
                                                    size: 48,
                                                  ),
                                                  SizedBox(height: 8),
                                                  Text(
                                                    '图片加载失败',
                                                    style: TextStyle(
                                                      color: AppColors
                                                          .textSecondary,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                                  if (_isEditMode)
                                    Positioned(
                                      right: 28,
                                      bottom: 12,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black54,
                                          borderRadius: BorderRadius.circular(
                                            16,
                                          ),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.camera_alt,
                                              color: Colors.white,
                                              size: 16,
                                            ),
                                            SizedBox(width: 4),
                                            Text(
                                              '更换照片',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Opacity(
                          opacity: _inputOpacity(),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 20),
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: AppColors.card,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextField(
                                  controller: _titleController,
                                  style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '给笔记起个名字（选填）',
                                    hintStyle: TextStyle(
                                      color: AppColors.hint,
                                      fontSize: 16,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                const Divider(height: 24),
                                TextField(
                                  controller: _contentController,
                                  maxLength: 500,
                                  maxLines: 4,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: AppColors.textPrimary,
                                    height: 1.6,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '写点想法...',
                                    hintStyle: TextStyle(
                                      color: AppColors.hint,
                                      fontSize: 15,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                    counterStyle: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                const Divider(height: 24),
                                TextField(
                                  controller: _bookNameController,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '关联书名（选填）',
                                    hintStyle: TextStyle(
                                      color: AppColors.hint,
                                      fontSize: 15,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                const Divider(height: 24),
                                TextField(
                                  controller: _bookPageController,
                                  keyboardType: TextInputType.number,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '页码（选填）',
                                    hintStyle: TextStyle(
                                      color: AppColors.hint,
                                      fontSize: 15,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _shutterFlashOpacity(),
                      duration: Duration.zero,
                      child: Container(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).padding.bottom + 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showSuccess)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '保存成功',
                      style: TextStyle(color: AppColors.accent, fontSize: 14),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: _saveBtnOpacity(),
                  duration: Duration.zero,
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _onSave,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        disabledBackgroundColor: AppColors.disabled,
                        foregroundColor: AppColors.onAccent,
                        disabledForegroundColor: AppColors.onAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        elevation: 0,
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.onAccent,
                              ),
                            )
                          : const Text('保存', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
