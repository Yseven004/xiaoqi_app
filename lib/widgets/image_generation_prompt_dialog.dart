import 'package:flutter/material.dart';

/// Dialog for guiding users to input image generation prompts.
/// Shows examples and quality tips.
class ImageGenerationPromptDialog extends StatefulWidget {
  const ImageGenerationPromptDialog({super.key});

  @override
  State<ImageGenerationPromptDialog> createState() =>
      _ImageGenerationPromptDialogState();
}

class _ImageGenerationPromptDialogState
    extends State<ImageGenerationPromptDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  int _selectedExample = -1;

  static const _examples = [
    {
      'label': '温馨卧室场景',
      'prompt': '温暖的卧室，阳光透过白色窗帘洒进来，窗台上有三盆绿植，床上躺着一只橙色的猫，墙上挂着串灯',
    },
    {
      'label': '赛博朋克城市',
      'prompt': '赛博朋克风格的城市夜景，霓虹灯闪烁，飞行汽车穿梭在高楼之间，街道上烟雾弥漫',
    },
    {
      'label': '抽象概念图',
      'prompt': '抽象概念图，中心是一个发光的核心，周围是层层剥离的半透明球体，简洁科技风，蓝紫色调',
    },
    {
      'label': '自然风光',
      'prompt': '日落时分的海边，天空渐变从橙红到深蓝，海浪轻拍沙滩，远处有一艘白色帆船',
    },
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _selectExample(int index) {
    setState(() {
      _selectedExample = index;
      _controller.text = _examples[index]['prompt']!;
    });
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 640),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.image_outlined, size: 28, color: Color(0xFF424242)),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    '创建图像',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF202124),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 22),
                  onPressed: () => Navigator.of(context).pop(),
                  constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '描述你想要生成的图片内容',
              style: TextStyle(color: Color(0xFF5F6368), fontSize: 14),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: '例如：温暖的卧室，窗台有三盆绿植，床上有一只橙猫...',
                hintStyle: const TextStyle(color: Color(0xFFAAAAAA)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFDDDDDD)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF1A73E8), width: 2),
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 20),
            const Text(
              '💡 提示：只描述视觉元素',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF424242),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('✅ ', style: TextStyle(fontSize: 13)),
                      Expanded(
                        child: Text(
                          '描述场景、主体、颜色、风格、氛围',
                          style: TextStyle(fontSize: 13, color: Color(0xFF188038)),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('❌ ', style: TextStyle(fontSize: 13)),
                      Expanded(
                        child: Text(
                          '不要包含"讲解""介绍"等任务指令',
                          style: TextStyle(fontSize: 13, color: Color(0xFFC5221F)),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('❌ ', style: TextStyle(fontSize: 13)),
                      Expanded(
                        child: Text(
                          '不要提及名人姓名或品牌名称',
                          style: TextStyle(fontSize: 13, color: Color(0xFFC5221F)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '或选择一个示例',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF5F6368),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(_examples.length, (index) {
                    final isSelected = _selectedExample == index;
                    return InkWell(
                      onTap: () => _selectExample(index),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFFE8F0FE)
                              : Colors.white,
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFF1A73E8)
                                : const Color(0xFFDDDDDD),
                            width: isSelected ? 2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _examples[index]['label']!,
                          style: TextStyle(
                            fontSize: 13,
                            color: isSelected
                                ? const Color(0xFF1A73E8)
                                : const Color(0xFF424242),
                            fontWeight: isSelected
                                ? FontWeight.w500
                                : FontWeight.normal,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF5F6368),
                    minimumSize: const Size(80, 40),
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _controller.text.trim().isEmpty ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1A73E8),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(100, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    elevation: 0,
                  ),
                  child: const Text('生成图片'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Show the image generation prompt dialog and return user input.
/// Returns null if user cancels.
Future<String?> showImageGenerationPromptDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => const ImageGenerationPromptDialog(),
  );
}
