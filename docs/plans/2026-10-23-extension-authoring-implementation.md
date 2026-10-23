# 统一扩展编辑接入记录

依据：[统一确认规格](../design/extension-market-v2/extension-editing-confirmed-2026-10-23.md)。2026-10-23 用户授权开始实现，并指定全局 MCP 默认图标使用上传参考中的双插头样式。

## 当前实施范围

- 复用技能已有的草稿、媒体、导入检查与预览发布能力，扩展为技能／插件共用编辑器；不引入新 SDK 或插件引擎。
- 插件主表单沿用确认稿；插件内容默认折叠，保留原包文件结构与真实组件检查。第三方安装记录不转成作者记录。
- MCP 连接配置增加可保存的图标，复用已有图标选择器；测试不保存，令牌留空保留现值。账号自己的自定义图标可覆盖默认图形。
- MCP 默认图标全局使用独立 `assets/icons/capabilities/mcp_connector.svg`，涵盖市场列表／详情、连接表单、聊天选择器与胶囊入口。
- 客户端与服务端共享 release 和 contract；服务端检查通过后按既有 main／CI 预构建／ECS 部署流程发布。Flutter 本地和真机验证按项目约定留给用户。

## Layout Spec 与资产

沿用技能已接入尺寸：834×1194 平板概念视口、约 30dp 页面留白、108dp 编辑图标、52dp 固定底部按钮；窄屏沿用现有断点与滚动、键盘避让。插件只替换类型和内容摘要，不改变确认稿布局。MCP 沿用最大 600dp 的既有连接弹窗，在名称左侧加入约 80dp 图标及更换按钮。

| 资产 | 来源与许可 | viewBox／显示尺寸 | 状态与消费组件 |
| --- | --- | --- | --- |
| `assets/icons/capabilities/mcp_connector.svg` | [Phosphor core regular/plugs.svg](https://github.com/phosphor-icons/core/blob/main/assets/regular/plugs.svg)，2026-10-23 读取原始路径；[MIT](https://github.com/phosphor-icons/core/blob/main/LICENSE)。复用原始轮廓，仅固定默认填充颜色。 | `0 0 256 256`；胶囊约18、菜单约20–25、列表约40、详情约82、连接表单约80dp外框。 | 独立预览后接入；状态通过背景、文字、禁用及语义颜色表达，不改图形；自定义图标属于连接数据。 |

独立预览：`.codex-artifacts/extension-authoring/mcp-connector.png`。用户参考是形状依据，不裁用截图。资产预览不构成 Flutter 页面或设备验证。

## 外部参考

检索日期 2026-10-23，只参考一手来源，不复制市场代码。

- [Agent Plugins 1.0 schema](https://agent-plugins.org/schemas/1.0.0/plugin.schema.json)：复用现有 manifest 与包结构校验，不新增清单标准。
- [Anthropic 官方插件目录](https://github.com/anthropics/claude-plugins-official)：参考插件内技能与组件分组；各包许可分别适用，本任务不复用目录或插件内容。
- 技能创建与 A2UI 沿用[已记录的官方及固定来源](2026-10-23-skill-authoring-implementation.md)，不重写现有协议。

## 交付状态

- 代码接入完成：共用技能／插件编辑器、同页导入、私有草稿恢复、预览发布、作者权限，以及 MCP 连接图标保存与全局默认图形。
- 服务端 `dart analyze lib test`：通过，无问题；完整 `dart test --reporter expanded`：191 项通过。覆盖插件包导入／发布／安装隔离、非法路径、公开包凭据拒绝、MCP 图标校验与原令牌保留。
- 变更文件 `dart format` 与 `git diff --check`：通过；格式化只能证明语法可解析，不等于 Flutter 编译通过。
- 独立 MCP SVG 已在 128×128 预览核对轮廓；页面同状态视觉对比尚未执行。
- 共享版本：`2026-10-23-extension-authoring-1`，API contract `21`。正在进入 main／CI 预构建／ECS 部署，部署结果以任务交付报告及 `.codex-artifacts/deploy/` 日志为准。
- 客户端 Flutter analyze／test／build／run 及真机验证按约定未执行，待用户本机验证。不得将资产预览或服务端测试当作客户端视觉验证。

## 回滚与验收

服务端沿用部署脚本的单一紧急恢复点与失败自动回滚。自定义 MCP 图标存储在账号连接记录，公开目录连接保持目录所有者管理；公开插件包仍走现有检查与不可变文件快照。无新增 SDK、无新的并行包格式。

客户端验收路径：添加技能／插件 → 编辑器 → 导入内容（原弹窗）→ 返回同一草稿 → 保存 → 预览 → 返回编辑或确认发布；重新进入可恢复。检查 MCP 列表／详情／聊天选择器默认双插头、自定义连接换图标与令牌留空保存。另核对窄屏、键盘、空状态、取消和错误提示。Ponytail 在本任务后恢复关闭。
