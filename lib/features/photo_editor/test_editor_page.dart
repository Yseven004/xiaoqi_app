import 'package:flutter/material.dart';
import 'photo_editor_page.dart';

/// 测试编辑器页面
class TestEditorPage extends StatelessWidget {
  const TestEditorPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('照片编辑器测试'),
        backgroundColor: Colors.white,
      ),
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            // 打开编辑器，使用一个测试图片路径
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => PhotoEditorPage(
                  imagePath: '', // 这里应该传入真实的图片路径
                  onCompleted: (path) {
                    debugPrint('编辑完成: $path');
                  },
                  onCancelled: () {
                    debugPrint('编辑取消');
                  },
                ),
              ),
            );
          },
          child: const Text('打开照片编辑器'),
        ),
      ),
    );
  }
}
