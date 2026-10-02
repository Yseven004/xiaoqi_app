import 'dart:async';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/ai_analysis_result.dart';
import '../models/note.dart';
import '../widgets/app_toast.dart';
import '../services/database_service.dart';

class AiAnalysisResultPage extends StatefulWidget {
  final AiAnalysisResult result;
  final Note originalNote;

  const AiAnalysisResultPage({
    super.key,
    required this.result,
    required this.originalNote,
  });

  @override
  State<AiAnalysisResultPage> createState() => _AiAnalysisResultPageState();
}

class _AiAnalysisResultPageState extends State<AiAnalysisResultPage>
    with SingleTickerProviderStateMixin {
  final DatabaseService _db = DatabaseService();
  bool _isSaving = false;
  bool _showSuccess = false;

  late AnimationController _starController;
  late Animation<double> _starRotation;
  late Animation<double> _starOpacity;
  late Animation<double> _section1Opacity;
  late Animation<double> _section2Opacity;
  late Animation<double> _section3Opacity;
  late Animation<double> _section4Opacity;
  late Animation<double> _section5Opacity;
  late Animation<double> _footerOpacity;
  late Animation<double> _saveBtnOpacity;

  @override
  void initState() {
    super.initState();
    _starController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    // ✨ 旋转动画
    _starRotation = Tween<double>(begin: 0, end: 2 * 3.14159).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(150 / 1800, 650 / 1800, curve: Curves.easeInOut),
      ),
    );

    _starOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(150 / 1800, 180 / 1800, curve: Curves.easeOut),
      ),
    );

    _section1Opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(300 / 1800, 600 / 1800, curve: Curves.easeOut),
      ),
    );

    _section2Opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(420 / 1800, 720 / 1800, curve: Curves.easeOut),
      ),
    );

    _section3Opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(540 / 1800, 840 / 1800, curve: Curves.easeOut),
      ),
    );

    _section4Opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(660 / 1800, 960 / 1800, curve: Curves.easeOut),
      ),
    );

    _section5Opacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(780 / 1800, 1080 / 1800, curve: Curves.easeOut),
      ),
    );

    _footerOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(900 / 1800, 1200 / 1800, curve: Curves.easeOut),
      ),
    );

    _saveBtnOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _starController,
        curve: const Interval(1100 / 1800, 1400 / 1800, curve: Curves.easeOut),
      ),
    );

    _starController.forward();
  }

  @override
  void dispose() {
    _starController.dispose();
    super.dispose();
  }

  Future<void> _onSaveAsNote() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final originalTitle = widget.originalNote.title.isNotEmpty
          ? widget.originalNote.title
          : '未命名笔记';

      final content = _formatAnalysisContent();
      final now = DateTime.now().toIso8601String();

      final note = Note(
        type: 'ai_generated',
        title: 'AI分析：$originalTitle',
        content: content,
        bookName: widget.originalNote.bookName,
        bookPage: widget.originalNote.bookPage,
        parentNoteId: widget.originalNote.id,
        createdAt: now,
        updatedAt: now,
      );

      await _db.insertNote(note);
      debugPrint('[XiaoQi] AiResult: 保存AI分析为笔记成功');

      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _showSuccess = true;
      });

      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[XiaoQi] AiResult: 保存失败: $e');
      setState(() => _isSaving = false);
      if (mounted) {
        AppToast.show(context, '保存失败，请重试');
      }
    }
  }

  String _formatAnalysisContent() {
    final buffer = StringBuffer();
    if (widget.result.whatRead.isNotEmpty) {
      buffer.writeln('### 📋 AI读到了');
      buffer.writeln(widget.result.whatRead);
      buffer.writeln();
    }
    if (widget.result.goodPoints.isNotEmpty) {
      buffer.writeln('### ✅ 记得不错的地方');
      buffer.writeln(widget.result.goodPoints);
      buffer.writeln();
    }
    if (widget.result.missingPoints.isNotEmpty) {
      buffer.writeln('### ⚠️ 还可以补充');
      buffer.writeln(widget.result.missingPoints);
      buffer.writeln();
    }
    if (widget.result.understandingCorrection.isNotEmpty) {
      buffer.writeln('### 💡 理解提醒');
      buffer.writeln(widget.result.understandingCorrection);
      buffer.writeln();
    }
    if (widget.result.thoughtQuestions.isNotEmpty) {
      buffer.writeln('### 🤔 想一想');
      buffer.writeln(widget.result.thoughtQuestions);
      buffer.writeln();
    }
    if (widget.result.encouragingComment.isNotEmpty) {
      buffer.writeln('---');
      buffer.write('💬 ${widget.result.encouragingComment}');
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final hasRead = r.whatRead.trim().isNotEmpty;
    final hasGood = r.goodPoints.trim().isNotEmpty;
    final hasMissing = r.missingPoints.trim().isNotEmpty;
    final hasCorrection = r.understandingCorrection.trim().isNotEmpty;
    final hasQuestions = r.thoughtQuestions.trim().isNotEmpty;
    final hasComment = r.encouragingComment.trim().isNotEmpty;
    final allEmpty = r.isEmpty;

    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('AI分析'),
          backgroundColor: AppColors.background,
          surfaceTintColor: AppColors.background,
          elevation: 0,
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const SizedBox(height: 24),
                      // ✨ 星星动画
                      AnimatedBuilder(
                        animation: _starController,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _starOpacity.value,
                            child: Transform.rotate(
                              angle: _starRotation.value,
                              child: const Text(
                                '✨',
                                style: TextStyle(fontSize: 32),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      AnimatedBuilder(
                        animation: _starOpacity,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _starOpacity.value,
                            child: const Text(
                              '分析完成',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 24),

                      if (allEmpty) ...[
                        const SizedBox(height: 40),
                        const Text(
                          '认真看了看，但好像没什么需要补充的。继续加油！',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.hint,
                          ),
                        ),
                      ],

                      // 📋 AI读到了
                      if (hasRead) _buildSection(
                        opacity: _section1Opacity,
                        emoji: '📋',
                        title: 'AI读到了',
                        content: r.whatRead,
                        color: AppColors.accent,
                      ),

                      // ✅ 记得不错的地方
                      if (hasGood) _buildSection(
                        opacity: _section2Opacity,
                        emoji: '✅',
                        title: '记得不错的地方',
                        content: r.goodPoints,
                        color: const Color(0xFF4CAF50),
                      ),

                      // ⚠️ 还可以补充
                      if (hasMissing) _buildSection(
                        opacity: _section3Opacity,
                        emoji: '⚠️',
                        title: '还可以补充',
                        content: r.missingPoints,
                        color: const Color(0xFFFF9800),
                      ),

                      // 💡 理解提醒
                      if (hasCorrection) _buildSection(
                        opacity: _section4Opacity,
                        emoji: '💡',
                        title: '理解提醒',
                        content: r.understandingCorrection,
                        color: r.understandingCorrection.contains('理解没偏差')
                            ? const Color(0xFF4CAF50)
                            : const Color(0xFF2196F3),
                      ),

                      // 🤔 想一想
                      if (hasQuestions) _buildSection(
                        opacity: _section5Opacity,
                        emoji: '🤔',
                        title: '想一想',
                        content: r.thoughtQuestions,
                        color: const Color(0xFF9C27B0),
                      ),

                      // 💬 点评
                      if (hasComment) AnimatedBuilder(
                        animation: _footerOpacity,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _footerOpacity.value,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 16),
                              child: Text(
                                '💬 ${r.encouragingComment}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontStyle: FontStyle.italic,
                                  color: AppColors.textSecondary,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 保存按钮
            AnimatedBuilder(
              animation: _saveBtnOpacity,
              builder: (context, child) {
                return Opacity(
                  opacity: _saveBtnOpacity.value,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        onPressed: (_isSaving || _showSuccess) ? null : _onSaveAsNote,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          disabledBackgroundColor:
                              _showSuccess ? AppColors.accent : AppColors.disabled,
                          foregroundColor: AppColors.onAccent,
                          disabledForegroundColor: AppColors.onAccent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          elevation: 0,
                        ),
                        child: _showSuccess
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.check, size: 20),
                                  SizedBox(width: 6),
                                  Text('已保存', style: TextStyle(fontSize: 16)),
                                ],
                              )
                            : _isSaving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppColors.onAccent,
                                    ),
                                  )
                                : const Text(
                                    '保存为笔记',
                                    style: TextStyle(fontSize: 16),
                                  ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({
    required Animation<double> opacity,
    required String emoji,
    required String title,
    required String content,
    Color color = AppColors.accent,
  }) {
    return AnimatedBuilder(
      animation: opacity,
      builder: (context, child) {
        return Opacity(
          opacity: opacity.value,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      emoji,
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ],
                ),
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 8),
                  height: 1.5,
                  width: double.infinity,
                  color: color.withValues(alpha: 0.3),
                ),
                Text(
                  content,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textPrimary,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}