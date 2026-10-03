# 小栖技能 / 插件 V1 视觉资产清单（评审稿）

## 来源与许可

- 创建图像、联网搜索、绘图和“管理我的能力”图标按用户提供的原型截图重绘为独立 SVG；图标统一使用 24×24 viewBox 与约 1.8px 描边，保留原型的轮廓、线宽和留白。
- “创建技能 / 插件”菜单行和技能插件胶囊共用 `skill_plugin_capsule.svg`，确保两个入口图标一致。
- Google Material Symbols 与 Pinterest 搜索没有提供其余四个图标的匹配素材，因此按用户裁图重建；没有把截图裁片作为界面图标。
- 菜单五项图标的独立 80×80 预览：[PNG 预览](skills-menu-prototype-icons-preview.png)、[HTML 预览](skills-menu-prototype-icons-preview.html)；其余图标总览：[skills-plugins-v1-icon-preview.svg](skills-plugins-v1-icon-preview.svg)。
- 能力标签书本与文档图标依据用户冻结原型中的小图标轮廓和颜色独立重建；预览：[capability-tag-icons-preview.html](capability-tag-icons-preview.html)，每个 SVG 以 80×80 显示。它们只用于已有能力条目及输入 / 消息标签。

## 资产映射

| 最终 SVG | 上游图标 / 来源 | viewBox | 计划显示尺寸 | 状态映射 | 消费组件 |
|---|---|---:|---:|---|---|
| assets/icons/capabilities/image.svg | 用户原型图标裁图 `codex-clipboard-78ddc408-6a3d-40b5-a7b8-bcff49403057.png`：相框、圆点与山形，按轮廓重绘 | 0 0 24 24 | 29 dp | 常态 | 创建图像入口 |
| assets/icons/capabilities/web_search.svg | 用户原型图标裁图 `codex-clipboard-78ddc408-6a3d-40b5-a7b8-bcff49403057.png`：经纬线地球与叠加放大镜，按组合轮廓重绘 | 0 0 24 24 | 29 dp | 常态 | 联网搜索入口 |
| assets/icons/capabilities/brush.svg | 用户原型图标裁图 `codex-clipboard-78ddc408-6a3d-40b5-a7b8-bcff49403057.png`：细线斜置铅笔，按轮廓重绘 | 0 0 24 24 | 29 dp | 常态 | 绘图入口 |
| assets/icons/capabilities/auto_stories.svg | auto_stories — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/auto_stories/v12/24px.svg) | 0 0 24 24 | 28–32 dp | 技能常态 | 技能分组行 |
| assets/icons/capabilities/description.svg | description — [Google SVG](https://fonts.gstatic.com/s/i/materialiconsoutlined/description/v12/24px.svg) | 0 0 24 24 | 28–32 dp | 插件常态 | 插件分组行 |
| assets/icons/capabilities/settings.svg | 原型截图 `codex-clipboard-fd6d7c19-42ad-4c0e-91dd-51bbcf0147cf.png`：八齿轮廓与空心圆心，按轮廓重绘 | 0 0 24 24 | 26 dp | 常态 | 管理我的能力入口 |
| assets/icons/capabilities/skill_plugin_capsule.svg | 技能插件胶囊既有 Google Material Symbols `extension` 原始路径 — [Google SVG](https://fonts.gstatic.com/s/i/short-term/release/materialsymbolsoutlined/extension/default/24px.svg) | 0 -960 960 960 | 18 dp 胶囊 / 29 dp 菜单行 | 常态 | 技能/插件功能胶囊、创建技能/插件菜单项 |
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
| assets/icons/capabilities/capability_skill_book.svg | 用户冻结原型中的彩色打开书本图标，独立 SVG 重建 | 0 0 48 48 | 28 dp 菜单 / 18 dp 标签 | 技能常态 | 技能分组行、输入标签、消息 |
| assets/icons/capabilities/capability_plugin_document.svg | 用户冻结原型中的蓝色 Documents 图标，独立 SVG 重建 | 0 0 48 48 | 28 dp 菜单 / 18 dp 标签 | 插件常态 | 插件分组行、输入标签、消息 |

## 页面稿与当前接入

| 原始视觉来源 | 最终稿 | viewBox / 画板 | 状态 | 消费者 |
|---|---|---|---|---|
| 用户冻结菜单截图（当前聊天附件） | [skills-plugins-v1-review.svg](skills-plugins-v1-review.svg)；第二张截图确认输入框上方轻量面板与黑白灰色调 | 0 0 1240 540 | 交互样稿已按确认稿调整；页面仍待同 viewport 视觉验收 | `SkillsPluginsComposerControls`、`_HomeComposer` |

菜单五项图标均按 80×80 独立预览；功能菜单图标按 29 dp 显示，管理图标 26 dp。技能/插件胶囊及菜单行使用同一拼图图标；MCP 胶囊保持与阅读任务一致的点击反馈。创建图像、联网搜索、绘图图标已接入菜单；对应能力仍显示未开放反馈。冻结截图中的「Documents」「书本变童话」只是参考例子，不会写入默认数据。阅读任务胶囊及其 `apps.svg` 资产不在本次修改范围内。
