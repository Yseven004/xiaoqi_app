import 'package:flutter/material.dart';

import 'notebook_shelf_page.dart';

/// 保留旧路由类名以兼容已有导航代码，实际入口已完全切换为新书架。
///
/// 旧的平铺式“笔记管理”页面不再向用户展示；历史笔记由数据库迁移统一归入
/// 默认笔记本，并从书架进入。
class NoteManagerPage extends StatelessWidget {
  const NoteManagerPage({super.key});

  @override
  Widget build(BuildContext context) => const NotebookShelfPage();
}
