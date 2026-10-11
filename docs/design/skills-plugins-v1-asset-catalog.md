# 小栖技能 / 插件 V1 视觉资产清单（评审稿）

## 来源与许可

- 创建图像、联网搜索、绘图和“管理我的能力”图标按用户提供的原型截图重绘为独立 SVG；图标统一使用 24×24 viewBox 与约 1.8px 描边，保留原型的轮廓、线宽和留白。
- “创建技能 / 插件”功能行和底部技能胶囊保留拼图图标；已保存能力条目、输入标签和已发送消息标签复用侧边栏扳手 SVG `assets/images/reading_sidebar_wrench.svg`，菜单条目与内联标签中的扳手为 18 dp。
- Google Material Symbols 与 Pinterest 搜索没有提供其余四个图标的匹配素材，因此按用户裁图重建；没有把截图裁片作为界面图标。
- 菜单五项图标的独立 80×80 预览：[PNG 预览](skills-menu-prototype-icons-preview.png)、[HTML 预览](skills-menu-prototype-icons-preview.html)；其余图标总览：[skills-plugins-v1-icon-preview.svg](skills-plugins-v1-icon-preview.svg)。
- 原能力标签书本与文档图标依据用户冻结原型中的小图标轮廓和颜色独立重建并保留；当前输入标签、技能 / 插件菜单条目和已发送消息统一复用侧边栏扳手图标。

## 资产映射

| 最终 SVG | 上游图标 / 来源 | viewBox | 计划显示尺寸 | 状态映射 | 消费组件 |
|---|---|---:|---:|---|---|
| assets/icons/capabilities/image.svg | 用户原型图标裁图 `codex-clipboard-78ddc408-6a3d-40b5-a7b8-bcff49403057.png`：相框、圆点与山形，按轮廓重绘 | 0 0 24 24 | 29 dp | 常态 | 创建图像入口 |
| assets/icons/capabilities/web_search.svg | 用户原型中的地球图标，按经纬线轮廓重绘；本次按用户要求移除放大镜 | 0 0 24 24 | 29 dp（预览 64×64） | 常态；启用状态由右侧原生 Switch 表示 | 联网搜索菜单行 |
| assets/icons/capabilities/brush.svg | 用户原型图标裁图 `codex-clipboard-78ddc408-6a3d-40b5-a7b8-bcff49403057.png`：细线斜置铅笔，按轮廓重绘 | 0 0 24 24 | 29 dp | 常态 | 绘图入口 |
| assets/icons/capabilities/auto_stories.svg | auto_stories — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/auto_stories/v12/24px.svg) | 0 0 24 24 | 28–32 dp | 技能常态 | 技能分组行 |
| assets/icons/capabilities/description.svg | description — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/description/v12/24px.svg) | 0 0 24 24 | 28–32 dp | 插件常态 | 插件分组行 |
| assets/icons/capabilities/settings.svg | 原型截图 `codex-clipboard-fd6d7c19-42ad-4c0e-91dd-51bbcf0147cf.png`：八齿轮廓与空心圆心，按轮廓重绘 | 0 0 24 24 | 26 dp | 常态 | 管理我的能力入口 |
| assets/images/reading_sidebar_wrench.svg | 侧边栏既有 Phosphor Icons regular Wrench，MIT — [Phosphor Icons](https://github.com/phosphor-icons/core) | 0 0 256 256 | 27 dp 侧栏 / 18 dp 菜单条目和内联标签 | 常态 | 侧栏入口、已保存能力条目、输入标签、已发送消息标签 |
| assets/icons/capabilities/skill_plugin_capsule.svg | 技能插件胶囊既有 Google Material Symbols `extension` 路径 — [Google SVG](https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/extension/default/24px.svg) | 0 -960 960 960 | 18 dp 胶囊 / 29 dp 创建入口 | 常态 | 技能 / 插件功能胶囊、“创建技能 / 插件”功能行 |
| assets/icons/capabilities/apps.svg | apps — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/apps/v12/24px.svg) | 0 0 24 24 | 24–28 dp | 常态 | 阅读任务底部入口 |
| assets/icons/capabilities/mcp_connector.svg | 依据冻结截图绘制的简线插头；Google Material Outlined 中未找到与此形状相符的连接器图标 | 0 0 24 24 | 24–28 dp | 常态 | MCP 连接器底部入口 |
| assets/icons/capabilities/help_outline.svg | help_outline — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/help_outline/v12/24px.svg) | 0 0 24 24 | 18–20 dp | 常态 | 智能体式选择面板标题 |
| assets/icons/capabilities/edit.svg | edit — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/edit/v12/24px.svg) | 0 0 24 24 | 20–24 dp | 常态 | 修改技能/插件 |
| assets/icons/capabilities/delete.svg | delete — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/delete/v12/24px.svg) | 0 0 24 24 | 20–24 dp | 危险操作 | 删除技能/插件 |
| assets/icons/capabilities/visibility.svg | visibility — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/visibility/v12/24px.svg) | 0 0 24 24 | 20–24 dp | 菜单展示开启 | 管理条目展示状态 |
| assets/icons/capabilities/visibility_off.svg | visibility_off — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/visibility_off/v12/24px.svg) | 0 0 24 24 | 20–24 dp | 菜单展示关闭 | 管理条目展示状态 |
| assets/icons/capabilities/cloud_upload.svg | cloud_upload — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/cloud_upload/v12/24px.svg) | 0 0 24 24 | 16–20 dp | 待同步 / 上传中 | 同步状态 |
| assets/icons/capabilities/cloud_done.svg | cloud_done — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/cloud_done/v12/24px.svg) | 0 0 24 24 | 16–20 dp | 已同步 | 同步状态 |
| assets/icons/capabilities/sync_problem.svg | sync_problem — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/sync_problem/v12/24px.svg) | 0 0 24 24 | 20–24 dp | 冲突 / 同步失败 | 冲突提示与恢复入口 |
| assets/icons/capabilities/capability_skill_book.svg | 用户冻结原型中的彩色打开书本图标，独立 SVG 重建 | 0 0 48 48 | 原 28 dp 菜单 / 18 dp 标签 | 技能常态 | 历史素材保留，当前界面未接入 |
| assets/icons/capabilities/capability_plugin_document.svg | 用户冻结原型中的蓝色 Documents 图标，独立 SVG 重建 | 0 0 48 48 | 原 28 dp 菜单 / 18 dp 标签 | 插件常态 | 历史素材保留，当前界面未接入 |

## 页面稿与当前接入

| 原始视觉来源 | 最终稿 | viewBox / 画板 | 状态 | 消费者 |
|---|---|---|---|---|
| 用户冻结菜单截图（当前聊天附件） | [skills-plugins-v1-review.svg](skills-plugins-v1-review.svg)；第二张截图确认输入框上方轻量面板与黑白灰色调 | 0 0 1240 540 | 交互样稿已按确认稿调整；页面仍待同 viewport 视觉验收 | `SkillsPluginsComposerControls`、`_HomeComposer` |

菜单五项图标均按 80×80 独立预览；功能菜单图标按 29 dp 显示，管理图标 26 dp。“创建技能 / 插件”功能行和底部胶囊保留拼图图标；已保存能力条目、输入标签和已发送消息标签使用侧边栏扳手图标，能力条目和内联标签中的扳手均为 18 dp。输入标签和消息气泡中的能力名称使用浅粉色强调，菜单标题保留原色。MCP 胶囊保持与阅读任务一致的点击反馈。创建图像、联网搜索、绘图图标已接入菜单；对应能力仍显示未开放反馈。冻结截图中的「Documents」「书本变童话」只是参考例子，不会写入默认数据。阅读任务胶囊及其 `apps.svg` 资产不在本次修改范围内。

联网搜索行在 `SkillsPluginsComposerControls` 中消费现有 `web_search.svg`；同一菜单行的 Flutter `Switch` 提供开启 / 关闭状态，不新增或栅格化视觉资产。

## 绘图画板工具图标

| 最终 SVG | 上游图标 / 来源与许可证 | viewBox | 显示尺寸 | 状态映射 | 消费组件 |
|---|---|---:|---:|---|---|
| assets/icons/drawing/mouse-pointer-2.svg | `mouse-pointer-2` — [Lucide Icons](https://github.com/lucide-icons/lucide/blob/main/icons/mouse-pointer-2.svg)，MIT — [许可证](https://github.com/lucide-icons/lucide/blob/main/LICENSE) | 0 0 24 24 | 21 dp | 选择工具启用时使用主题色 | `DrawingBoardPage` 工具栏 |
| assets/icons/drawing/shapes.svg | `shapes` — [Lucide Icons](https://github.com/lucide-icons/lucide/blob/main/icons/shapes.svg)，MIT — [许可证](https://github.com/lucide-icons/lucide/blob/main/LICENSE) | 0 0 24 24 | 21 dp | 形状工具启用时使用主题色 | `DrawingBoardPage` 形状菜单 |
| assets/icons/drawing/eraser.svg | `eraser` — [Lucide Icons](https://github.com/lucide-icons/lucide/blob/main/icons/eraser.svg)，MIT — [许可证](https://github.com/lucide-icons/lucide/blob/main/LICENSE) | 0 0 24 24 | 21 dp | 橡皮擦启用时使用主题色 | `DrawingBoardPage` 工具栏 |
| assets/icons/drawing/check.svg | `check` — [Lucide Icons](https://github.com/lucide-icons/lucide/blob/main/icons/check.svg)，MIT — [许可证](https://github.com/lucide-icons/lucide/blob/main/LICENSE) | 0 0 24 24 | 23 dp | 完成按钮白色；处理中由现有按钮内小圈反馈 | `DrawingBoardPage` 完成按钮 |
| assets/icons/capabilities/brush.svg | 项目既有“绘图”入口 SVG，见本表上方的原型重绘记录 | 0 0 24 24 | 21 dp | 手绘启用时使用主题色 | `DrawingBoardPage` 工具栏 |
| assets/icons/chat_note_editor/text-aa.svg | 项目既有文字工具 SVG | 0 0 24 24 | 21 dp | 文字启用时使用主题色 | `DrawingBoardPage` 工具栏 |
| assets/icons/chat_note_editor/arrow-counter-clockwise.svg；arrow-clockwise.svg | 项目既有撤销 / 重做 SVG | 0 0 24 24；0 0 256 256 | 21 dp | 无历史动作时浅灰禁用 | `DrawingBoardPage` 工具栏 |
| assets/icons/capabilities/image.svg | 项目既有图像入口 SVG | 0 0 24 24 | 21 dp | 常态 | `DrawingBoardPage` 导入底图按钮 |
| assets/icons/chat_note_editor/x.svg | 项目既有关闭 SVG | 0 0 256 256 | 22 dp | 常态 | `DrawingBoardPage` 关闭按钮 |

四个 Lucide SVG 在 `assets/icons/drawing/icon-preview.html` 以 64×64 CSS 像素独立预览；所有画板工具图标均作为独立矢量文件接入，不使用截图裁片或业务代码绘制替代。
