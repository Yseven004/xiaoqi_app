import 'dart:async';
import '../widgets/action_chip.dart';
import '../widgets/app_toast.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../config/api_config.dart';
import '../config/colors.dart';
import '../models/note.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import 'ai_analysis_result_page.dart';
import 'text_note_detail_page.dart';
import 'photo_note_detail_page.dart';

class AiNoteDetailPage extends StatefulWidget {
  final Note note;

  const AiNoteDetailPage({super.key, required this.note});

  @override
  State<AiNoteDetailPage> createState() => _AiNoteDetailPageState();
}

class _AiNoteDetailPageState extends State<AiNoteDetailPage> {
  final DatabaseService _db = DatabaseService();
  final AiService _aiService = AiService();
  late Note _note;
  Note? _parentNote;
  bool _isDeleted = false;
  int _todayUsage = 0;
  bool _isReanalyzing = false;

  @override
  void initState() {
    super.initState();
    _note = widget.note;
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      // 软删除检查
      final current = await _db.getNoteById(widget.note.id!);
      if (current == null || current.isDeleted == 1) {
        if (mounted) {
          setState(() => _isDeleted = true);
          AppToast.show(context, '该笔记已删除');
          Navigator.of(context).pop();
        }
        return;
      }

      // 查询原笔记（如果有 parent_note_id）
      Note? parentNote;
      if (_note.parentNoteId != null) {
        final p = await _db.getNoteById(_note.parentNoteId!);
        if (p != null && p.isDeleted == 0) {
          parentNote = p;
        }
      }

      // 查询今日AI使用次数
      final usage = await _aiService.getTodayUsageCount();

      if (mounted) {
        setState(() {
          _note = current;
          _parentNote = parentNote;
          _todayUsage = usage;
        });
      }
      debugPrint('[XiaoQi] AiNote: 加载详情 id=${_note.id}, 原笔记=${parentNote?.id}, 今日AI=$usage');
    } catch (e) {
      debugPrint('[XiaoQi] AiNote: 加载异常: $e');
    }
  }

  Future<void> _onReanalyze() async {
    if (_isReanalyzing) return;

    try {
      if (_todayUsage >= ApiConfig.dailyAiLimit) {
        if (mounted) {
          AppToast.show(context, '今日分析次数已用完');
        }
        return;
      }

      // 需要原笔记存在
      if (_parentNote == null) {
        if (mounted) {
          AppToast.show(context, '原笔记不存在，无法重新分析');
        }
        return;
      }

      setState(() => _isReanalyzing = true);
      debugPrint('[XiaoQi] AiNote: 重新分析原笔记 id=${_parentNote!.id}');

      final result = await _aiService.analyzeNote(_parentNote!).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('[XiaoQi] AiNote: 重新分析超时');
          throw TimeoutException('AI分析超时');
        },
      );

      if (!mounted) return;

      // 计次
      await _aiService.recordUsage(_parentNote!.id!);
      final newCount = await _aiService.getTodayUsageCount();

      if (!mounted) return;
      setState(() {
        _todayUsage = newCount;
        _isReanalyzing = false;
      });

      // 跳转结果页
      await Navigator.push(
        context,
        CupertinoPageRoute(
          builder: (_) => AiAnalysisResultPage(
            result: result,
            originalNote: _parentNote!,
          ),
        ),
      );
      if (mounted) _loadData();
    } on TimeoutException {
      if (mounted) {
        setState(() => _isReanalyzing = false);
        AppToast.show(context, 'AI服务暂时不可用，稍后再试');
      }
    } catch (e) {
      debugPrint('[XiaoQi] AiNote: 重新分析异常: $e');
      if (mounted) {
        setState(() => _isReanalyzing = false);
        AppToast.show(context, 'AI服务暂时不可用，稍后再试');
      }
    }
  }

  void _onParentNoteTap() {
    if (_parentNote == null) return;
    Widget page;
    if (_parentNote!.type == 'photo') {
      page = PhotoNoteDetailPage(note: _parentNote!);
    } else {
      page = TextNoteDetailPage(note: _parentNote!);
    }
    Navigator.push(
      context,
      CupertinoPageRoute(builder: (_) => page),
    );
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
            '确定删除这条分析吗？',
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
        debugPrint('[XiaoQi] AiNote: 软删除 id=${_note.id}');
        if (mounted) Navigator.of(context).pop();
      } catch (e) {
        debugPrint('[XiaoQi] AiNote: 删除失败: $e');
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
    final hasParentId = _note.parentNoteId != null;
    final isParentDeleted = hasParentId && _parentNote == null;
    final isAiDisabled = _todayUsage >= ApiConfig.dailyAiLimit;

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
              const Text('AI分析', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 12),
              InlineActionChip(label: '删除', onTap: _onDelete, isDelete: true),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      // 分析内容全文
                      if (_note.content.isNotEmpty)
                        Text(
                          _note.content,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w400,
                            color: AppColors.textPrimary,
                            height: 1.6,
                          ),
                        ),
                      if (_note.content.isEmpty) ...[
                        const SizedBox(height: 20),
                        const Text(
                          '空分析',
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.hint,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      // 关联原笔记
                      if (hasParentId) ...[
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: AppColors.disabled,
                        ),
                        const SizedBox(height: 16),
                        GestureDetector(
                          onTap: isParentDeleted ? null : _onParentNoteTap,
                          child: Row(
                            children: [
                              const Text(
                                '📎 关联原笔记',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  isParentDeleted
                                      ? '原笔记已删除'
                                      : (_parentNote?.title.isNotEmpty == true
                                          ? _parentNote!.title
                                          : '未命名笔记'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isParentDeleted
                                        ? AppColors.hint
                                        : AppColors.accent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // 分析时间
                      const SizedBox(height: 12),
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
            // 重新分析按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: SizedBox(
                height: 48,
                child: OutlinedButton(
                  onPressed:
                      (_isDeleted || isAiDisabled || _isReanalyzing)
                          ? null
                          : _onReanalyze,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.accent,
                    disabledForegroundColor: AppColors.hint,
                    side: BorderSide(
                      color: isAiDisabled
                          ? AppColors.disabled
                          : AppColors.accent,
                      width: 1.5,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                  child: _isReanalyzing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accent,
                          ),
                        )
                      : Text(
                          isAiDisabled ? '今日次数已用完' : '重新分析',
                          style: const TextStyle(fontSize: 16),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
