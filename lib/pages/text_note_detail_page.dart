import 'dart:async';
import '../widgets/app_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/ai_analysis_result.dart';
import '../models/note.dart';
import '../services/database_service.dart';
import '../widgets/action_chip.dart';
import '../widgets/ai_analyze_button.dart';
import 'ai_analysis_result_page.dart';
import 'text_note_edit_page.dart';

class TextNoteDetailPage extends StatefulWidget {
  final Note note;

  const TextNoteDetailPage({super.key, required this.note});

  @override
  State<TextNoteDetailPage> createState() => _TextNoteDetailPageState();
}

class _TextNoteDetailPageState extends State<TextNoteDetailPage>
    with SingleTickerProviderStateMixin {
  final DatabaseService _db = DatabaseService();
  late Note _note;
  bool _isDeleted = false;
  late AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _fadeController.forward();
    });
    _checkDeletedAndLoad();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
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
      debugPrint('[XiaoQi] TextDetail: 加载成功 id=${_note.id}');
    } catch (e) {
      debugPrint('[XiaoQi] TextDetail: 加载异常: $e');
    }
  }

  void _onAnalysisComplete(AiAnalysisResult result) {
    debugPrint('[XiaoQi] TextDetail: AI分析完成');
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
        builder: (_) => TextNoteEditPage(existingNote: _note),
      ),
    );
    if (mounted) {
      final updated = await _db.getNoteById(_note.id!);
      if (updated != null && updated.isDeleted == 0) {
        setState(() => _note = updated);
      } else if (updated == null || updated.isDeleted == 1) {
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
            style: TextStyle(
              fontSize: 14,
              color: AppColors.hint,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                '删除',
                style: TextStyle(color: AppColors.error),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      try {
        await _db.softDelete(_note.id!);
        debugPrint('[XiaoQi] TextDetail: 软删除笔记 id=${_note.id}');
        if (mounted) Navigator.of(context).pop();
      } catch (e) {
        debugPrint('[XiaoQi] TextDetail: 删除失败: $e');
        if (mounted) {
          AppToast.show(context, '删除失败，请重试');
        }
      }
    }
  }

  String _formatFullTime(String iso8601) {
    try {
      final dt = DateTime.parse(iso8601);
      final month = dt.month.toString().padLeft(2, '0');
      final day = dt.day.toString().padLeft(2, '0');
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$month-$day $hour:$minute';
    } catch (_) {
      return iso8601;
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
                  child: FadeTransition(
                    opacity: _fadeController,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 20),
                          if (hasTitle)
                            Text(
                              _note.title,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          if (hasContent) ...[
                            const SizedBox(height: 12),
                            Text(
                              _note.content,
                              style: const TextStyle(
                                fontSize: 16,
                                color: AppColors.textPrimary,
                                height: 1.6,
                              ),
                            ),
                          ],
                          if (hasBook) ...[
                            const SizedBox(height: 16),
                            Row(
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
                          ],
                          if (!hasTitle && !hasContent && !hasBook) ...[
                            const SizedBox(height: 20),
                            const Text(
                              '空笔记',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppColors.hint,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Text(
                            '🕐 ${_formatFullTime(_note.createdAt)}',
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.hint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AiAnalyzeButton(
                    note: _note,
                    onAnalysisComplete: _onAnalysisComplete,
                  ),
                  // AiUsageIndicator 由 AiAnalyzeButton 内部管理
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
