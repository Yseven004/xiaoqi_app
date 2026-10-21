# 回复文字注释交互修正

2026-10-21，Operate 模式。用户已确认五项修正，以及“点击上箭头保存非空内容后，才显示气泡并计数”。本记录覆盖文字注释创建、取消、编辑和汇总，不改变图片点位创建规则。

## 证据与问题

- 用户录屏 `093adb247e15c9402b94e133025d33b3.mp4`：720×1152，41.5 秒。可见文字选区、点位偏离、输入框覆盖原文，以及空注释进入聊天输入区计数。约 16–28 秒展示输入框与点位，约 28–40 秒展示空注释被计入。
- 用户录屏 `a47129a70697f44dbd008b7fac8fe36d.mp4`：720×1152，约 5.83 秒。约 2–5 秒，列表编辑框漂在列表弹窗上方。录屏未展示键盘展开后的最终状态。
- 两段录屏的尺寸是视频像素尺寸，不能据此推断设备 dp、字体缩放或系统键盘高度。抽帧仅用于排查，不作为生产素材。
- 代码原因：创建前就调用 `_applyAnnotations`；关闭编辑器时将控制器内容当作提交结果；输入框使用 `anchor.dy - 90`；列表编辑传入固定 y=180；文字点位按外框而非 SVG 底部圆点定位，且被容器边界截断坐标。

## 本次冻结交互

1. 选择原文后进入临时草稿。保留选区高亮；未保存时不生成编号点位，不加入汇总、计数、持久化或下一条 AI 消息。原文和已有注释保持不变。
2. 新建输入框位于选区最后一行下方，间距 8 dp，默认不打开键盘。输入框跟随原文排版与滚动；键盘和多行输入可能遮挡时预留消息列表滚动空间，将原文末行及输入框一起移入可视区域。
3. 仅点击上箭头或键盘完成动作可提交非空内容，首尾空白去除。空白输入时提交按钮禁用。点击外部、切换文本或返回均取消本次草稿，外部触摸继续传递，不需要先点一次关闭遮罩。修改现有注释时，取消保留原值。
4. 保存后才出现连续编号、点位及汇总气泡。点位使用实际排版文字矩形，将 `pin.svg` 的底部圆点中心对齐选区末行右下角。用户于 2026-10-21 确认的汇总样式为：注释计数与清除按钮在输入区顶部组成同一枚白底浅灰描边胶囊，中间以细竖线分隔；清除图形使用既有独立 `x.svg`，显示为 16×16 dp，置于 34×34 dp 浅灰圆底内，点击区域为 48×48 dp。清空语义不变。视觉参考保存在 `.codex-artifacts/chat-annotations/references/chat-annotation-tray-selected-2026-10-21.png`。
5. 点击汇总列表中的注释，输入框直接在键盘上方 8 dp 展开并聚焦，采用阅读任务搜索框的键盘 inset 跟随方式；取消或收起已展开的键盘时退出编辑。保存更新该条，不增加数量。

## 实现与数据边界

- `chatTextQuoteBoxes` 统一创建输入框与已有点位的真实文字测量；继续沿用原文、选区 offset 和来源摘要，不改变源消息。
- 文字编辑使用单个可关闭的 `OverlayEntry` 与 `TapRegion`，替代拦截整屏触摸的评论对话框；`LocalHistoryEntry` 承接系统返回。输入控制器由浮层组件持有并随组件销毁。
- 首页只允许一个活动编辑器；切换会话、替换编辑器或离开页面时关闭原编辑器，并清理键盘布局锁。创建期间的额外底部留白仅用于保留原文可视空间。
- 恢复旧草稿时忽略没有评论文字的文字引用，消除旧逻辑残留的空注释；不触及历史消息正文或图片注释。现有非空注释、图片编辑数据、附件和发送失败恢复机制继续使用既有格式。
- 没有新依赖、API 格式、后端或部署配置变化。回退限于本次 Flutter 与对应规格改动；服务端保持现有健康版本。

## 固定 SVG 使用记录

| 来源与路径 | viewBox | 显示尺寸 | 状态及消费组件 |
| --- | --- | --- | --- |
| 项目既有 `assets/icons/chat_note_editor/x.svg` | 0 0 256 256 | 16×16 dp，34×34 dp 圆底 | 石墨色；`ChatAnnotationTray` 清空按钮；点击区域 48×48 dp |
| 项目既有 `assets/icons/chat_annotations/pin.svg` | 0 0 40 54 | 36×48.6 dp，容器 48×54 dp | 蓝底白边，数字实时文字；`ChatAnnotationPin`；底部点中心在容器内 (24, 44.1) |

本次复用既有 SVG，无新绘制或位图替代；没有运行独立渲染或页面截图，实际尺寸视觉仍待验收。旧规格中的 pin 显示尺寸记录与现有组件不符，本记录按现有组件数值说明，不声称已通过视觉验收。

## 外部参考

2026-10-21 检索以下一手来源，仅参考设计与平台机制，不直接复制第三方代码：

- [AppFlowy Editor](https://github.com/AppFlowy-IO/appflowy-editor)，检索时 main 的 [pubspec](https://raw.githubusercontent.com/AppFlowy-IO/appflowy-editor/main/pubspec.yaml) 为 6.1.0；[许可证](https://github.com/AppFlowy-IO/appflowy-editor/blob/main/LICENSE) 双授权 AGPLv3 / MPL 2.0。参考其 [编辑器架构说明](https://appflowy.com/blog/demystifying-appflowy-editors-codebase) 中选区菜单与工具浮层独立管理的方式，不引入编辑器依赖。
- Flutter 官方 [getBoxesForSelection](https://api.flutter.dev/flutter/rendering/RenderParagraph/getBoxesForSelection.html)：布局完成后以真实文字矩形定位；多行和双向文字可有多个矩形。
- Flutter 官方 [OverlayEntry](https://api.flutter.dev/flutter/widgets/OverlayEntry-class.html)、[TapRegion](https://api.flutter.dev/flutter/widgets/TapRegion-class.html)、[viewInsets](https://api.flutter.dev/flutter/widgets/MediaQueryData/viewInsets.html)、[LocalHistoryEntry](https://api.flutter.dev/flutter/widgets/LocalHistoryEntry-class.html)：分别用于浮层生命周期、外部触摸透传、键盘边界和系统返回。

## 分层交付状态与验收

- 代码实现：已接入上述五项交互；仅执行 Dart 格式化，不代表编译或行为验证。
- 回归代码：补充了点位末行对齐、重排、取消不提交且外部触摸透传、非空显式提交、草稿无编号点位、列表编辑跟随键盘及键盘收起取消的用例；未运行。
- 自动化/静态检查：未运行 `dart analyze`、`flutter test` 或构建。
- 同状态视觉对比：未执行。用户录屏仅证明原问题，不证明修正已有效。
- 真机/目标平台：未执行验证，待用户真机验证。ARTEMIS 工具未提供，本次未执行设备操作。

真机优先路径：长按回复原文 → 注释 → 不输入直接选择另一段（应无计数且原草稿退出）→ 输入文字但不提交后取消（应无计数）→ 输入并点上箭头（应计为 1 条）→ 打开列表修改（输入框应在键盘上方）→ 保存、取消、收起键盘分别确认计数与原值 → 清空后气泡消失。追加检查底部原文、多行选区、长评论、横竖屏、字体放大、滚动后点位及会话切换。

服务端：server deployment not needed，改动仅限 Flutter UI 与本地注释状态，服务器运行代码和 API 契约未改变。
