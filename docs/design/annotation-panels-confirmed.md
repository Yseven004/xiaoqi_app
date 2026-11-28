# 注释面板确认规格

2026-11-25。三张确认图依次覆盖伴读目录与注释、主界面输入、伴读录音和回看。参考是竖屏平板，原有真机记录为 800 × 1280 dp。确认图是比例示意，以下逻辑尺寸是 Flutter 接入目标。版本范围为注释界面与伴读面板导航。

| 确认图 | 源文件 |
| --- | --- |
| 目录与注释 | `codex-clipboard-dc43f36a-e35e-4adf-8d3a-eae2f4cd6d58.png` |
| 主界面注释 | `codex-clipboard-44854a16-7236-4597-9e2b-a3765cac9b89.png` |
| 录音与音频附件 | `codex-clipboard-f74554d3-af07-462c-9235-d548a0e6f9fe.png` |

| 位置 | 接入约束 |
| --- | --- |
| 主界面输入 | 全宽贴键盘。两侧各用 44 dp 等宽触控位及 12 dp 外边距，输入区占余宽。加号与发送箭头视觉重量接近。引文与加号描边左缘对齐，仅显示单行摘录。 |
| 伴读注释 | 从正文或注释列表直接进入同一编辑面板。新建注释须点「保存」，返回手势或点面板外会丢弃草稿。已有注释打开时键盘收起，「保存」、返回手势或点面板外都会提交修改，全部清空时按删除处理，内容未变时直接退出。提交成功后直接回正文，失败时保留编辑内容和面板。「加入笔记库」使用已保存的版本。 |
| 图片与录音 | 主界面和伴读都在选图、移除图片时保留输入焦点，伴读的录音和回听控件也保留焦点。系统相册或权限窗口返回后恢复原先打开的键盘。两处注释编辑面板都随系统键盘的实际高度移动，键盘收起时回到窗口底部安全区。 |
| 删除注释 | 长按后显示屏幕居中的轻量黑白确认框。「取消」靠左，「删除」靠右并沿用原有尺寸和样式。取消保留记录，确认后删除并刷新列表。 |
| 录音 | 状态与停止方块共享浅蓝色胶囊。淡阴影只用于胶囊，停止方块有独立的 44 dp 触控区和读屏名称。停止后显示灰色回听附件，保存仍由用户触发。 |
| 阅读器底栏 | 目录、注释、进度、显示四个等宽入口。目录和注释共用面板容器，章节标题与目录标题左对齐。注释列表按已有数据展示；有稳定 PDF 锚点时显示原页码。 |
| 点击和焦点 | 面板按钮用平面样式，保留键盘焦点提示。全局输入焦点规则见 [DESIGN.md](../../DESIGN.md#components)。单行引文可点开全文。录音进行中和媒体操作未完成时保持原有保护，失败提示并允许重试。 |

## SVG 资产

| 图形 | 项目资产和 viewBox | 接入与状态 |
| --- | --- | --- |
| 加号 | [现有阅读任务加号](../../assets/images/reading_task_plus.svg)，24 × 24 | 主界面 30 × 30 dp、伴读编辑器 27 × 27 dp 画布，禁用时降为灰色 |
| 发送 | [现有注释上箭头](../../assets/icons/chat_annotations/arrow-up.svg)，24 × 24 | 主界面 24 × 24 dp 白色箭头画布，36 dp 圆形容器根据是否可发送变色 |
| 停止录音 | [现有停止方块](../../assets/icons/note_format/stop.svg)，24 × 24 | 录制中显示，20 × 20 dp 画布，蓝色方块 |
| 注释底栏 | [现有注释气泡](../../assets/icons/chat_annotations/comment.svg)，24 × 24 | 底栏，手机 18 dp、平板 25 dp，沿用阅读配色和选中底色 |
| 回听 | [现有播放图标](../../assets/icons/note_format/play_arrow.svg) 和 [现有暂停图标](../../assets/icons/note_format/pause.svg)，24 × 24 | 沿用回听附件的播放、暂停和时长。 |

加号、发送、停止方块、注释气泡已做独立 64 × 64 资产预览。用户确认本轮复用 App 已有图标。

沿用项目锁定的 Flutter 3.47.5，继续使用现有底部面板、返回保护和焦点行为。[Flutter 底部面板](https://api.flutter.dev/flutter/material/showModalBottomSheet.html) · [Flutter 返回保护](https://api.flutter.dev/flutter/widgets/PopScope-class.html) · [Flutter 点击反馈](https://api.flutter.dev/flutter/material/InkWell-class.html)

Android 系统返回在注释编辑器位于前台时交给 Flutter 导航处理，避免输入法先消费返回。系统相册沿用原生选择器。[Android 返回调度](https://developer.android.com/reference/android/window/OnBackInvokedDispatcher) · [旧版 Android 输入法前置按键](https://developer.android.com/reference/kotlin/android/view/View#onKeyPreIme(kotlin.Int,android.view.KeyEvent)) · [Flutter 恢复键盘](https://api.flutter.dev/flutter/widgets/EditableTextState/requestKeyboard.html)

## 交付与验收

- 代码已按确认规格接入。录音回听沿用现有播放器的图标与时长。
- 真机验收依次看主界面有无键盘时的按钮与摘录对齐、已有注释直接编辑与退出、录音开始及停止回听、底栏目录与注释切换。核对 800 × 1280 dp 平板，并在手机窄屏及大字号下检查布局。
- 同状态视觉对照与设备交互未执行验证，待用户真机验证。
