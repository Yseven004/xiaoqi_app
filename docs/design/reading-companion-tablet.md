# 平板伴读 · 选段问答

2026-11-20 确认了平板电子书视图中选中原文、打开问答、输入区菜单收起的状态。[查看确认原图](reading-companion/confirmed/tablet-selection-chat-2026-11-20.png)。

- 顶栏「阅读空间」保持可见，伴读按钮在笔记左侧。选文上方的黑色胶囊从左到右为「复制」「注释」「AI」。
- 在 900 × 1350 的参考画布中，问答卡尺寸为 540 × 720，宽高比 3:4。卡片位于选文下方，顶部直接显示引文，右上是收起和关闭。卡片无标题、无指向尖角。
- 卡内使用黑白灰对话排版，用户消息靠右，回答靠左。底部双层输入栏在参考画布中高 84，首行用于输入，次行左侧为「＋」，右侧依次为脑形模型按钮、语音和发送。收起状态的模型按钮仅显示脑形图标。

该图是平板问答窗收起菜单时的视觉定稿。2026-11-20 同步确认了「＋」菜单的切换方式、空状态与安装入口。[查看确认的四种子卡状态](reading-companion/confirmed/tablet-companion-menu-states-2026-11-20.png)。模型面板沿用主界面的模型和思考程度控件，入口仅显示脑形图标。

## 「＋」展开后的交互要求

- 一级菜单在「＋」按钮正上方弹出。三个入口从上到下依次是「文件」「技能 / 插件」「MCP 连接器」，每行图标在左、名称在右。「文件」使用用户提供的回形针样式，另两项复用首页的 `skill_plugin_capsule.svg` 和 `mcp_connector.svg`。
- 点任一入口，同一次点按即收起一级菜单，并在伴读输入框正上方展开该类别的选择卡。选择卡位于伴读窗内，下沿贴近输入框上沿，输入框保持可见且位置固定。三个入口共用这个位置，每次只显示一张卡。关闭选择卡后回到同一段问答，保留输入草稿。
- 三张子卡与输入框等宽，下沿对齐在输入框上方。在 900 × 1350 的平板参考画布中，卡宽 504，距输入框 8。高度由可见内容撑开，最后一行下面只保留常规内边距。文件卡按三个来源自然收高。技能 / 插件卡和 MCP 卡分别受各自上限及可用空间约束，前者允许展示更多内容。
- 列表超出上限时，仅列表区上下滚动。标题、关闭按钮和输入框保持原位，背景对话保留原滚动位置。技能 / 插件卡顶部的「创建图像」「绘图」也保持可见。
- 三张选择卡的列表项均可整行点按，统一去掉行末的右箭头「›」。
- 「文件」列出图片、本地文件和微信文件三个来源。点「图片」可以从相册选择或拍照。
- 「创建图像」和「绘图」是常驻入口。任何安装状态下都可以直接点按，两项操作与下面的可安装内容分开。已安装条目按「技能」「插件」分区展示。只有一类为空时，在该区给出去安装的入口；两类都为空时，在常驻入口下合并为一行提示「还没有安装技能或插件」，点「去安装」进入市场。
- 「MCP 连接器」列出本轮可用的连接器。尚未安装或添加任何连接器时，点「去安装连接器」进入插件市场内可安装的 MCP 目录。已添加但暂不可用时引导用户管理现有连接。读取失败时提供重试，保留已有条目。

## 阅读器图标

图标在 Flutter 中统一以 18 × 18 显示，点击区由对应控件提供。2026-11-20 在独立 64 × 64 预览中核对边界、轮廓、比例和线宽。

| 图标 | 最终 SVG 与来源 | viewBox | 状态与组件 |
| --- | --- | --- | --- |
| 收起 | `assets/images/reading_companion_minimize.svg`，按确认稿的水平短线重建 | 0 0 24 24 | 问答窗展开时可用 |
| 关闭 | `assets/icons/extension_market/detail/close.svg`，复用插件市场关闭图标 | 0 0 256 256 | 问答窗展开时可用 |
| 继续问答 | `assets/icons/extension_market/detail/chat-dots.svg`，复用现有线性会话图标 | 0 0 256 256 | 问答窗收起时可用 |
| 目录 | `assets/icons/note_format/format_list_bulleted.svg`，复用笔记格式列表图标 | 0 0 24 24 | 底栏，资料就绪时可用 |
| 文字大小 | `assets/icons/chat_note_editor/text-aa.svg`，复用笔记编辑器图标 | 0 0 256 256 | 底栏，可重排资料可用 |
| 切换资料 | `assets/images/reading_task_book.svg`，复用阅读任务书本图标 | 0 0 24 24 | 底栏，有多份资料时可用 |

## 伴读输入区图标资产

下表记录独立 SVG 与 `ReadingCompanionComposer` 中的显示尺寸。形状核对使用 64 × 64 的独立预览。Flutter 实际界面待同状态截图验收。

| 用途 | 路径及来源 | viewBox / 显示尺寸 | 状态 |
| --- | --- | --- | --- |
| 模型按钮 | `assets/images/reading_companion_model_brain.svg`，Lucide 0.468.0（ISC） | 0 0 24 24 / 19 dp | 收起和展开均显示脑形。确认稿上的脑形来自位图参考，Lucide 版的内部线条略有差异。 |
| 添加、语音、发送 | `assets/images/home_composer_add.svg`、`home_composer_microphone.svg`、`home_send_idle.svg`、`home_send_active.svg`、`home_send_stop.svg`，沿用首页资产 | 0 0 40 40 / 28 dp | 发送根据输入和生成状态选用闲置、可发送或停止图标。 |
| 文件、技能 / 插件、MCP 连接器 | `assets/icons/extension_market/detail/paperclip.svg`、`assets/icons/capabilities/skill_plugin_capsule.svg`、`assets/icons/capabilities/mcp_connector.svg`，沿用市场和首页资产 | 见独立 SVG / 17 dp | 图标常驻，点击整行切换面板。 |
| 附件来源和常驻操作 | `assets/images/home_attachment_*.svg`、`assets/icons/capabilities/image.svg`、`assets/icons/capabilities/brush.svg`，沿用首页资产 | 见独立 SVG / 17 dp | 每行点按；创建图像、绘图始终可用。 |
