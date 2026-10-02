import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../models/editor_state.dart';

/// 底部主工具栏
class EditorToolbar extends StatelessWidget {
  final EditorTool currentTool;
  final Function(EditorTool) onToolSelected;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onCancel;
  final VoidCallback onComplete;

  const EditorToolbar({
    super.key,
    required this.currentTool,
    required this.onToolSelected,
    required this.onUndo,
    required this.onRedo,
    required this.canUndo,
    required this.canRedo,
    required this.onCancel,
    required this.onComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).padding.bottom + 12,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // 画笔工具
          _buildToolItem(
            icon: Icons.edit_outlined,
            label: '画笔',
            tool: EditorTool.pen,
          ),

          // 裁剪工具
          _buildToolItem(
            icon: Icons.crop,
            label: '裁剪',
            tool: EditorTool.crop,
          ),

          // 马赛克工具
          _buildToolItem(
            icon: Icons.grid_on,
            label: '马赛克',
            tool: EditorTool.mosaic,
          ),

          // 完成按钮
          _buildCompleteButton(),
        ],
      ),
    );
  }

  /// 构建工具项
  Widget _buildToolItem({
    required IconData icon,
    required String label,
    required EditorTool tool,
  }) {
    final isSelected = currentTool == tool;

    return GestureDetector(
      onTap: () => onToolSelected(tool),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: isSelected ? AppColors.accent : Colors.white,
            size: 24,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isSelected ? AppColors.accent : Colors.white,
              fontSize: 12,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }

  /// 构建完成按钮
  Widget _buildCompleteButton() {
    return GestureDetector(
      onTap: onComplete,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          '完成',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}
