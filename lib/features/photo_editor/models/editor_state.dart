/// 编辑器工具类型
enum EditorTool {
  none,    // 未选择工具
  pen,     // 画笔
  crop,    // 裁剪
  mosaic,  // 马赛克
}

/// 编辑器状态
enum EditorState {
  idle,      // 画布空闲
  drawing,   // 画笔/马赛克绘制中
  cropping,  // 裁剪模式：手柄可拖拽
}
