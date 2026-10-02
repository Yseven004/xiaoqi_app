import 'dart:async';
import '../widgets/app_toast.dart';
import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/note.dart';
import '../services/database_service.dart';

class TextNoteEditPage extends StatefulWidget {
  final Note? existingNote;

  const TextNoteEditPage({super.key, this.existingNote});

  @override
  State<TextNoteEditPage> createState() => _TextNoteEditPageState();
}

class _TextNoteEditPageState extends State<TextNoteEditPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _slideCtrl;
  late Animation<double> _slideProgress;

  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();
  final TextEditingController _bookNameController = TextEditingController();
  final TextEditingController _bookPageController = TextEditingController();
  final FocusNode _contentFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _isSaving = false;
  bool _showSuccess = false;
  final DatabaseService _db = DatabaseService();

  bool get _isEditMode => widget.existingNote != null;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _slideProgress = CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.elasticOut,
    );
    if (_isEditMode) {
      final note = widget.existingNote!;
      _titleController.text = note.title;
      _contentController.text = note.content;
      _bookNameController.text = note.bookName;
      _bookPageController.text = note.bookPage;
    }
    _slideCtrl.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _contentFocusNode.requestFocus();
        }
      });
    });
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _bookNameController.dispose();
    _bookPageController.dispose();
    _contentFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }



  Future<void> _onSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    try {
      final now = DateTime.now().toIso8601String();
      final note = Note(
        id: widget.existingNote?.id,
        type: 'text',
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
        bookName: _bookNameController.text.trim(),
        bookPage: _bookPageController.text.trim(),
        createdAt: widget.existingNote?.createdAt ?? now,
        updatedAt: now,
      );

      if (_isEditMode) {
        final current = await _db.getNoteById(widget.existingNote!.id!);
        if (current == null || current.isDeleted == 1) {
          if (mounted) {
            AppToast.show(context, '该笔记已被删除');
            Navigator.of(context).pop();
          }
          return;
        }
        await _db.update(note);
        debugPrint('[XiaoQi] TextEdit: 更新笔记 id=${note.id}');
      } else {
        await _db.insertNote(note);
        debugPrint('[XiaoQi] TextEdit: 新建笔记成功');
      }

      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _showSuccess = true;
      });

      await Future.delayed(const Duration(milliseconds: 400));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      debugPrint('[XiaoQi] TextEdit: 保存失败: $e');
      setState(() => _isSaving = false);
      if (mounted) {
        AppToast.show(context, '保存失败，请重试');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomPadding = MediaQuery.of(context).padding.bottom + 80;
    const horizontalPadding = 20.0;

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
                _isEditMode ? '修改笔记' : '新建笔记',
                style: const TextStyle(fontSize: 16),
              ),
              backgroundColor: AppColors.background,
              surfaceTintColor: AppColors.background,
              elevation: 0,
            ),
            body: AnimatedBuilder(
              animation: _slideProgress,
              builder: (context, child) {
                final sw = MediaQuery.of(context).size.width;
                final offset = sw * (_slideProgress.value - 1.0);
                return Transform.translate(
                  offset: Offset(offset, 0),
                  child: child,
                );
              },
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: EdgeInsets.only(bottom: bottomPadding),
                child: Column(
                  children: [
                    const SizedBox(height: 20),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: horizontalPadding),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.card,
                        borderRadius: BorderRadius.circular(16),
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
                                fontSize: 18,
                              ),
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const Divider(
                            height: 25,
                            thickness: 1,
                            color: AppColors.disabled,
                          ),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: screenHeight * 0.6,
                            ),
                            child: TextField(
                              controller: _contentController,
                              focusNode: _contentFocusNode,
                              minLines: 6,
                              maxLines: null,
                              style: const TextStyle(
                                fontSize: 16,
                                color: AppColors.textPrimary,
                                height: 1.6,
                              ),
                              decoration: const InputDecoration(
                                hintText: '写点什么...',
                                hintStyle: TextStyle(
                                  color: AppColors.hint,
                                  fontSize: 16,
                                ),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          const Divider(
                            height: 25,
                            thickness: 1,
                            color: AppColors.disabled,
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _bookNameController,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '书名（选填）',
                                    hintStyle: TextStyle(
                                      color: AppColors.hint,
                                      fontSize: 14,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              SizedBox(
                                width: 80,
                                child: TextField(
                                  controller: _bookPageController,
                                  keyboardType: TextInputType.number,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: '页码',
                                    hintStyle: TextStyle(
                                      color: AppColors.hint,
                                      fontSize: 14,
                                    ),
                                    border: InputBorder.none,
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).padding.bottom + 24,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeIn,
              child: SizedBox(
                height: 48,
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_isSaving || _showSuccess) ? null : _onSave,
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
                          : const Text('保存', style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
