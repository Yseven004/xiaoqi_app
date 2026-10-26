# 详细介绍与介绍图片：内部高度核验

日期：2026-10-24。

## 本轮用户确认范围

- 最外层白色弹窗的高度、位置不变；添加内容、补充资料主页面、确认页面的布局不变。
- 只处理详细介绍编辑与介绍图片编辑的内部可用高度，不把先前评审中的文字、图标、菜单样式等差异一并扩入。
- 原稿参照：`approved-details/modal-creation-2026-10-23/description-focused-editor.png`、`images-focused-editor.png`。本轮是内部高度修正，不声明整个界面已严格还原。

## 实测与处理

采用实际创建入口 `showExtensionCreation`，834×1251 逻辑 viewport、项目 NotoSansCJKSC 字体。同一份普通技能草稿在全部步骤和编辑态共用外框：左 83.4、顶 293.985、右 750.6、底 987.873 dp（记录取三位小数）。

| 项目 | 修改前实测 | 本轮处理 |
| --- | --- | --- |
| 详细介绍正文 | 顶约 366 dp、底与外框底一致 | 已满高，保留现有 `expands` 约束；测试正文底边及键盘出现时的可见边界 |
| 无图添加框 | 高 520 dp，底与外框底相差约 102 dp | 移除 520 dp 上限；按实际剩余高度减去 24 dp 底部空间，实测高约 598 dp；宽高比保留 3:4 |
| 有图横向画廊 | 固定上限及最小值使高度利用不完整，小可视区可能溢出 | 高度取实际剩余空间减去 76 dp（说明区域及底部空间）；图片保持原比例，末尾添加框跟随末图 |
| 横向滚动提示 | 没有显式可见滚动条 | 复用 Flutter Scrollbar 和 ScrollController；放在底部空间内，距外框底 12 dp；不额外增高外框 |
| 图片网格编辑 | Wrap 在有限高度内不能自行滚动 | 只在编辑画布外加内部纵向滚动，保留网格列宽、比例和拖动排序 |

## 分层验证

- 代码：仅修改编辑器画廊高度计算、滚动及其控制器生命周期；详细介绍与外层尺寸计算不改。
- 自动检查：8 项定向测试通过，包含原有创建流程及新增高度回归；测试平板 834×1251、手机 390×844、空图 3:4、有图说明、布局切换、模拟键盘、外框坐标不变。
- 静态分析：无 error，存在 45 条既有 warning/info；原始日志 `.codex-artifacts/canvas-layout-analyze.txt`。
- 视觉：两轮有界检查已完成，修正首轮发现的滚动条贴底；实际截图确认内部高度及固定外框。使用测试图像和模拟键盘 inset，不能代表真实输入法验证。
- 构建：`flutter build apk --debug --no-pub` 成功，APK 为 `build/app/outputs/flutter-apk/app-debug.apk`；日志 `.codex-artifacts/canvas-layout-build.txt`。
- 真机：未执行验证，待用户真机验证。

截图证据存于已忽略目录 `.codex-artifacts/creation-2026-10-24/`：`canvas-images-empty-before.png`、`canvas-images-empty.png`、`canvas-description.png`、`canvas-images-834.png`、`canvas-images-390.png`、`canvas-keyboard-834.png`、`canvas-keyboard-390.png`、`canvas-grid-834.png`、`canvas-grid-390.png`。测试日志 `.codex-artifacts/canvas-layout-test.txt`。

server deployment not needed：仅 Flutter 本地布局与回归测试，未修改服务端、API 合约或部署文件。
