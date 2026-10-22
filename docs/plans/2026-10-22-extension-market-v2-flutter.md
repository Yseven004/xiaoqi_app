# 扩展市场 V2 · Flutter 前端实现

当前状态：用户要求暂停 Flutter 实现，先补齐缺失后端。尚未修改 Flutter 页面、入口或资产登记；只完成现状核对与本计划。后端工作另见同日扩展包上传计划。恢复前端时继续以已确认原型为准。

## 冻结范围

2026-10-22，用户已验收 `docs/design/extension-market-v2/prototype/` 的 HTML 原型并授权开始 Flutter 前端实现，特别要求按钮和图标还原。后端、API 契约与部署保持当前版本。本任务取代 V1 的彩色合集、卡片和三个顶层页签。

视觉依据：原型 CSS / React 结构为第一依据；三张 `approved-details/` 图片是详情构图依据，开发者的用户修正「第七世界即小七官方」优先于图片旧文字。官方名称集中配置；真实导入内容的作者、来源、版本和安装状态不可替换为演示元数据。

## 本轮布局规格

| 区域 | 平板 / 宽窗 | 手机 / 窄窗 | 状态 |
| --- | --- | --- | --- |
| 画布 | 最大宽 1040，左右 32；参考预览 834 宽 | 左右 20；参考预览 390 宽 | SafeArea、键盘避让、系统返回 |
| 市场 | 仅插件 / 技能；搜索 50 高；条目双列、列间距 36 | 列表单列；搜索 48 高 | 搜索、公开/个人、已安装、分类、草稿 |
| 类型/操作 | 44 高胶囊；黑色添加；图标 20–25 | 触控目标至少 44，粗指针优先 48 | 按下、焦点、选中、禁用；静态加载 |
| 插件/MCP详情 | 面包屑、82 图标、28 标题、横向动作；浅灰 310 提示词区 | 66 图标、25 标题；动作换行，示例自然增高 | 安装、授权、管理、试用、复制、卸载 |
| 技能详情 | 居中标题、104 图标、30 名称；折叠介绍、案例三列 | 70 图标、25 名称；案例单列 | 固定底部操作，已安装与未安装分开 |
| 编辑器 | 文件侧栏约 29%，220–330；正文独立滚动 | 文件抽屉切换；正文真实编辑 | 校验、草稿恢复、保留/放弃/继续、文件操作 |
| 表单/浮层 | 白底、20–28 圆角；弹窗最大约 600 | 四周 18–20；受键盘高度约束 | 字段错误、任务进行、取消、成功反馈 |

灰阶使用原型局部 token：`#191919`、`#6b6b6b`、`#e8e8e8`、`#f4f4f4`、白色；按钮 `#1d1d1d`。不修改全 App 主题。正文 14–17、章节 19–20，沿用 Android / 项目现有中文字体；字体跨平台差异需用户对比。

## 实现安排

1. 提取原型同源独立 SVG，预览、登记资产，保留许可；报告 SVG 的文字转为字体矢量轮廓供 Flutter 使用，不裁整页 PNG。
2. 替换市场首页、分类/已安装、详情与管理外观，复用现有数据和错误处理。
3. 接入已确认的聊天新会话、编辑器/草稿、上传和 MCP 表单路径。
4. 更新受影响调用方、测试规格和交付记录；用户自行执行 Flutter 本地/真机验收。

## 现有能力与边界

- `CapabilityStore` 已支持草稿、版本、base64 附件文件和本地保存；`CapabilityCloudSync` 保持既有同步契约。不得为 UI 改变云端请求格式。
- GitHub 检查/安装/取消/更新复用 `runImportOperation`；MCP 目录、安装、OAuth、保存、测试、重连和删除复用现有 API。
- 本地技能 Markdown / 技能包可解析成既有草稿，再由用户检查后保存；保留路径、大小、文件数和内容校验，不执行脚本。
- 后端补齐任务已增加本地插件/技能包检查与安装接口，复用现有导入任务；Flutter 接入 `capabilityImportPolicy` 与 `inspectCapabilityUpload`，不绕过检查伪造安装。详见 `2026-10-22-extension-package-upload-backend.md`。
- 后端已增加未保存 MCP 草稿测试，Flutter 使用 `testMcpConnectionDraft`；不得因点击测试暗中保存连接。
- 目录、版本和权限信息以实际记录为准；缺失信息使用空/未提供状态，不把原型演示工具或应用列表当成服务端返回。

## 外部参考与取舍

检索日期 2026-10-22；只参考，不新增 UI 框架或依赖：

- [Flutter 官方响应式最佳实践](https://docs.flutter.dev/ui/adaptive-responsive/best-practices)：使用现有 LayoutBuilder / 约束决定列数，兼顾窗口和文字缩放。文档无独立包版本；来源为 Flutter 官方。
- [Flutter 官方无障碍](https://docs.flutter.dev/ui/accessibility/ui-design-and-styling)：保留系统文字缩放、语义、键盘与触控目标。
- [flutter_svg 2.3.0](https://pub.dev/packages/flutter_svg)：仓库现有依赖，使用 `SvgPicture.asset` 和颜色映射；项目采用 MIT 许可证。优先复制原型同源 SVG，避免相近 Material 图标替换。
- [Phosphor core](https://github.com/phosphor-icons/core)：成熟原始 SVG 图标仓库，MIT；实际形状由原型固定依赖 `@phosphor-icons/react 2.1.10` 导出，原始矢量和许可一起交付，不从截图自动描边。

## 验收与回滚

当前技能规定本任务未获明确的本地验证授权，因此不执行 `dart analyze`、`flutter test/build/run`、设备操作、Flutter 截图或视觉 diff。仅编辑源码、资产和测试规格，记录为「已按规格接入，未执行验证，待用户真机验证」。不以 HTML 验收或资产预览冒充 Flutter 验收。

回滚范围只涉及本任务 Flutter 页面、对应调用与新增 SVG / pubspec 资产登记；不迁移、删除既有安装记录、草稿或服务器数据。若需要回滚，按本任务 diff 恢复前端文件，保留用户数据。

仓库当前未找到技能引用的 `docs/ui/ui-design-workflow.md` 和 `docs/product/xiaoqi-product-requirements-backlog.md`，本任务依据现有 `PRODUCT.md`、`DESIGN.md`、当前能力模型/代码以及本轮冻结原型执行，不伪造缺失文档。

server deployment not needed：仅 Flutter 前端、资产和文档；服务端与 API 契约不变。
