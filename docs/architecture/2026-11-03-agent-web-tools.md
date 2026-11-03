# Agent 内置网页感知工具（2026-11-03）

## 已确认的产品与交互

- 面向普通对话和技能任务，Agent 按信息缺口自主搜索或读取公开网页，不需要技能 ID 或用户开关。
- 删除技能/插件菜单中的联网搜索行，沿用对话过程、来源链接、失败提示和停止操作。公开网页只读；登录、填表、购买与浏览器自动操作后置。
- 用户明确禁止联网时遵守；问候、改写、纯创作无需搜索。不新增页面和视觉资产。遵守空输入收键盘失焦、有内容保留、按钮当次点击执行和静态页面占位规则。

## 工具契约与实现

- `web_search(query, purpose?, limit=5)`：query 1–128 字符，purpose 最多 300 字符，limit 1–10。返回公开来源、URL 来源 ID、时间、提供商与摘要证据类型。
- `web_fetch(url, start_char=0, max_chars=12000)`：公开 HTTP(S)，禁止凭据、本机/内网/元数据及非标准端口；解析 DNS 并检查服务返回的目标 URL。max_chars 为 1–20000，按 Unicode 码点分页。
- TinyFish 官方 REST Search / Fetch，服务端密钥 `TINYFISH_API_KEY`；缺失或请求失败最多降级 DeepSeek 一次。正常空搜索不降级；无效 URL、明确不存在和登录要求不绕过。服务端不接收 Agent 指定提供商或认证头。
- 正文上限 500000 码点，超出明确标记不完整；单次 TinyFish 响应上限 4 MiB。读取结果复用现有任务执行日志，恢复与分页读取同一份正文。不同任务/账号由现有执行范围隔离。
- 取消关闭该轮网页 HTTP 客户端，取消后不启动兜底。沿用工具操作预算。只在过程诊断中记录提供商、降级类别；不记录密钥或完整查询材料。
- 网页作为不可信外部资料，不能执行网页指令、索取秘密或自动上传会话。搜索摘要不能冒充已阅读全文；回答引用返回的真实链接。
- 客户端会话忽略旧 network_mode，移除更新接口。脚本仍默认隔离，只允许经过现有技能/精确域名授权的联网，不从旧开关继承公网权限。插件 Agent 继续遵守父级允许与禁止规则。
- `/v1/web/fetch` 复用统一服务，保留 title/content。客户端和服务端使用发布 `2026-11-03-agent-web-tools`、API 契约 `28`；旧客户端需重新构建。

## 外部参考与取舍

检索日期 2026-11-03；沿用 Genkit/Schemantic 1.0、现有 http 库，无新增运行时依赖。

- [TinyFish Search](https://docs.tinyfish.ai/search-api/reference)、[Fetch](https://docs.tinyfish.ai/fetch-api/reference)、[认证](https://docs.tinyfish.ai/authentication)：使用官方 REST，不引入完整浏览器自动化。
- [官方 MCP Server](https://github.com/tinyfish-io/tinyfish-mcp-server)，包版本 0.1.0、MIT：仅参考搜索和正文读取的职责划分，不直接复用 Node 代码。
- [Anthropic 工具设计实践](https://www.anthropic.com/research/writing-tools-for-agents)：职责明确、精简参数、渐进读取、明确错误与真实工具评测。

## 配置、验收与发布

- 服务器尚无 TinyFish 密钥，由用户通过受保护环境配置补齐；不得在聊天发送。缺少密钥不阻塞代码/模拟接口测试；不能宣称 TinyFish 实际调用通过。
- 自动测试覆盖主服务协议、正常空结果、来源限制、错误兜底、取消、分页、历史数据迁移、危险地址及插件权限。真实模型自主决策、真实 TinyFish、整页视觉和真机须分别记录证据。
- 按 deploy_current.ps1 发布，同步版本检查、预构建产物、健康/数据门禁和失败回滚；只保留当前版本与一个应急恢复点。不得以代码完成代称生产验证。
- 当前执行日志位于 `.codex-artifacts/web-tools/`；最终部署日志由标准部署脚本保存。未执行真机验证，待用户真机验证。
