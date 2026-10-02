import 'dart:async';
import '../widgets/app_toast.dart';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/ai_analysis_result.dart';
import '../models/note.dart';
import '../services/database_service.dart';
import '../widgets/action_chip.dart';
import '../widgets/ai_analyze_button.dart';
import 'ai_analysis_result_page.dart';
import 'photo_note_edit_page.dart';

class PhotoNoteDetailPage extends StatefulWidget {
  final Note note;

  const PhotoNoteDetailPage({super.key, required this.note});

  @override
  State<PhotoNoteDetailPage> createState() => _PhotoNoteDetailPageState();
}

class _PhotoNoteDetailPageState extends State<PhotoNoteDetailPage> {
  final DatabaseService _db = DatabaseService();
  late Note _note;
  bool _isDeleted = false;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _checkDeletedAndLoad();
  }

  Future<void> _checkDeletedAndLoad() async {
    try {
      final current = await _db.getNoteById(widget.note.id!);
      if (current == null || current.isDeleted == 1) {
        if (mounted) {
          setState(() => _isDeleted = true);
          AppToast.show(context, '该笔记已删除');
          Navigator.of(context).pop();
        }
        return;
      }
      debugPrint('[XiaoQi] PhotoDetail: 加载成功 id=${_note.id}');
    } catch (e) {
      debugPrint('[XiaoQi] PhotoDetail: 加载异常: $e');
    }
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
                    File(_note.photoPath),
                    key: ValueKey(_note.photoPath), // 使用路径作为 key 强制刷新
                    gaplessPlayback: true, // 编辑完成后平滑过渡
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) {
                      return const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.broken_image,
                                color: AppColors.textSecondary, size: 48),
                            SizedBox(height: 8),
                            Text('图片加载失败',
                                style: TextStyle(color: AppColors.textSecondary)),
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

  void _onAnalysisComplete(AiAnalysisResult result) {
    debugPrint('[XiaoQi] PhotoDetail: AI分析完成');
    Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => AiAnalysisResultPage(
          result: result,
          originalNote: _note,
        ),
      ),
    );
  }

  Future<void> _onEdit() async {
    await Navigator.push(
      context,
      CupertinoPageRoute(
        builder: (_) => PhotoNoteEditPage(
          imagePath: _note.photoPath,
          existingNote: _note,
        ),
      ),
    );
    if (mounted) {
      final updated = await _db.getNoteById(_note.id!);
      if (updated != null && updated.isDeleted == 0) {
        setState(() => _note = updated);
      } else {
        if (mounted) {
          setState(() => _isDeleted = true);
          AppToast.show(context, '该笔记已删除');
          Navigator.of(context).pop();
        }
      }
    }
  }

  Future<void> _onDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text(
            '确定删除这条笔记吗？',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          content: const Text(
            '删除后无法恢复',
            style: TextStyle(fontSize: 14, color: AppColors.hint),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(color: AppColors.error)),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      try {
        await _db.softDelete(_note.id!);
        debugPrint('[XiaoQi] PhotoDetail: 软删除笔记 id=${_note.id}');
        if (mounted) Navigator.of(context).pop();
      } catch (e) {
        debugPrint('[XiaoQi] PhotoDetail: 删除失败: $e');
        if (mounted) {
          AppToast.show(context, '删除失败，请重试');
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasTitle = _note.title.isNotEmpty;
    final hasContent = _note.content.isNotEmpty;
    final hasBook = _note.bookName.isNotEmpty || _note.bookPage.isNotEmpty;

    return PopScope(
      canPop: !_isDeleted,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          titleSpacing: 0,
          backgroundColor: AppColors.background,
          surfaceTintColor: AppColors.background,
          elevation: 0,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('笔记详情', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 12),
              InlineActionChip(label: '修改', onTap: _onEdit),
              const SizedBox(width: 6),
              InlineActionChip(label: '删除', onTap: _onDelete, isDelete: true),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),
                      GestureDetector(
                        onTap: _openFullScreenImage,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 20),
                          width: double.infinity,
                          constraints: const BoxConstraints(maxHeight: 360),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: AppColors.placeholder,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.file(
                            File(_note.photoPath),
                            key: ValueKey(_note.photoPath), // 使用路径作为 key 强制刷新
                            gaplessPlayback: true, // 编辑完成后平滑过渡
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 60),
                                child: Column(
                                  children: [
                                    Icon(Icons.broken_image,
                                        color: AppColors.textSecondary, size: 48),
                                    SizedBox(height: 8),
                                    Text('图片加载失败',
                                        style: TextStyle(
                                            color: AppColors.textSecondary,
                                            fontSize: 14)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (hasTitle)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            _note.title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                      if (hasContent) ...[
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Text(
                            _note.content,
                            style: const TextStyle(
                              fontSize: 16,
                              color: AppColors.textPrimary,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                      if (hasBook) ...[
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Row(
                            children: [
                              const Icon(Icons.menu_book,
                                  size: 16, color: AppColors.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                '${_note.bookName}${_note.bookName.isNotEmpty && _note.bookPage.isNotEmpty ? ' · ' : ''}${_note.bookPage}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: AiAnalyzeButton(
                note: _note,
                onAnalysisComplete: _onAnalysisComplete,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
