# 三步创建弹窗实施记录

依据：creation-modal-confirmed-2026-10-23.md。2026-10-24 用户授权实现、本地分析／测试／构建；真机由用户验收。

## 冻结范围与决策

- 技能、插件（含 MCP）共用添加内容、补充资料、确认三步；同一草稿、固定外框、内部滚动。查看原位展开，文字和图片编辑进入同框专注画布。
- 用户确认：公开插件仅含服务器地址与接入说明；令牌存本人私有连接，安装者各自授权；已有连接不自动发布、不批量迁移。
- 复用 account-scoped CapabilityDraft、现有作者发布权限、导入检查任务和插件依赖解析。不新增数据库，不改变草稿与公开版本分离规则。
- 图片排版存 presentation.image_layout，仅 horizontal／grid；旧记录缺省 horizontal。媒体仍用现有受限 data URI，保留现有图片数／大小限制。
- 客户端与服务端统一 release 2026-10-24-extension-creation-1、API contract 22；版本不一致阻断现有接口调用。

## 布局与资产

- 参考图 993×1584 为布局依据，非 dp；原型目标平板竖屏 834×1194。弹窗宽上限 670 dp、高上限 850 dp，距 viewport 四周至少 18／24 dp；各步和编辑状态尺寸不变。手机宽度随可用空间收缩，操作可换行；键盘占用内部内容区域。
- 图标、名称同排，简介独占一行；详细介绍和图片默认收起。确认页复用只读详情组件。
- 横向画廊保持原图比例，末尾添加框跟随最后一图；空画廊为 3:4。两种布局共用图片和顺序。
- 新 SVG：assets/icons/extensions/gallery-horizontal.svg、gallery-grid.svg，viewBox 0 0 24 24，显示 22×22；前者两张左右并排卡片，后者四格。来源为已确认布局含义的独立矢量重建；消费创建弹窗图片布局按钮与菜单，菜单勾选映射 horizontal／grid。Flutter 独立 64×64 渲染已检查；预览为 asset-previews/gallery-horizontal-64.png 与 gallery-grid-64.png。
- 其他图标复用 extension_market/detail、extensions/github_mark.svg；不裁剪设计稿，也不加入截图中的示例作品。

## 参考研究（2026-10-24）

- [Flutter Dialog API](https://api.flutter.dev/flutter/material/Dialog-class.html)、[Dialog build](https://api.flutter.dev/flutter/material/Dialog/build.html)、[PopScope](https://api.flutter.dev/flutter/widgets/PopScope-class.html)：官方当前文档；参考约束、键盘 inset 与系统返回行为，不复制实现代码。Flutter 原生 Dialog 默认结合 viewInsets 移动，故固定外框采用受约束 Material，键盘留白在内部。
- [mcp_dart v2.4.2](https://github.com/leehack/mcp_dart/tree/v2.4.2)、[许可证](https://github.com/leehack/mcp_dart/blob/v2.4.2/LICENSE)：MIT，检索到当前发布为 2.4.2；参考远程 MCP 的客户端与凭据分离。项目已有服务端连接测试／私有连接／插件声明解析，继续复用，无新增依赖或代码复制。
- [MCP 授权规范](https://modelcontextprotocol.io/specification/latest/basic/authorization)：参考安装者各自授权；不将作者令牌写入可发布包。

## 技术影响、失败与回滚

- 导入保留服务端检查及候选选择，覆盖已有编辑需确认；失败不替换当前草稿。发布前本机保存，发布失败留在当前确认页。
- MCP 测试只调用现有 connection-tests，不保存、不发布；修改使结果失效。私有凭据不进入 presentation、插件文件或 AI 请求。离线草稿令牌按账号／草稿 ID 存系统安全存储，并绑定服务器地址；地址改变后不复用旧令牌。联网保存时写本人私有连接；删除草稿同时清理本机令牌。已安装插件在管理菜单按声明提供连接设置，安装者自行填写令牌；不修改公开包。
- 发布时服务端同时拒绝 MCP 地址内的账号信息或 query，避免通过地址夹带凭据。MCP 兼容组件返回地址供安装者设置连接；执行仍由既有按账号及 URL 的依赖解析和权限检查决定。
- 服务端只新增排版字段校验和规范化，旧记录不重写。部署按 deploy_current.ps1；运行失败自动恢复唯一应急版本；不在 ECS 编译。
- 不支持的插件执行方式仍由现有服务端报告；统一创建界面不扩大本地脚本或宿主执行权限。

## 验收记录

- 客户端 17 项定向测试通过（创建弹窗、草稿、上传契约和市场入口）；服务端 12 项测试通过（纯 MCP 发布／安装、图片排版、凭据拒绝与既有作者权限）。草稿删除测试覆盖晚到云端记录不会重新落回本机。
- 客户端定向分析无错误、无警告，96 条样式提示；以 --no-fatal-infos 执行，退出码 0。服务端相关文件分析无问题，退出码 0。差异空白检查通过。
- Android 构建：第一次工具环境缺少已配置的 GRADLE_USER_HOME，停在 wrapper，超过 MCP 5 分钟上限；已停止本次挂起进程，改用项目本机环境重跑。不得交付 2026-10-23 的旧 APK 作为本次构建。
- 同状态页面截图比较未执行；无应用或设备操作。未执行真机验证，待用户真机验证。SVG 独立预览不冒充页面视觉验收。
- 服务端部署、健康、数据与清理待部署脚本完成后另记；此时不能宣称已上线或已验证任务效果。
