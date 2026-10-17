# 小七 Genkit Dart 单机部署

当前部署包含 Dart API、私有 Docker 沙箱执行器和 Caddy。Dart 服务提供兼容 Flutter 的 HTTP API，并在容器内提供 Genkit MCP；Caddy 负责公开 HTTPS、转发 API，并在转发 `/mcp` 前检查现有单人登录会话。沙箱执行器只在服务器内部接收任务，唯一能访问 Docker socket 的是这个受限执行器；用户代码容器不会拿到 socket 或主机目录。没有管理后台，模型、邮件、图片和沙箱配置全部从服务器环境变量读取。

Flutter 继续使用原有 HTTP 协议，不需要升级 Flutter 或添加 Genkit Flutter 客户端依赖。技能和草稿的本地数据仍由 Flutter 保存；服务端保留已有云端同步 API 与 SQLite 文档/对象格式。

## 服务器配置

在服务器进入 `xiaoqi_harness/deploy`，复制示例并编辑仅存于服务器的文件：

```sh
cp single-server.env.example single-server.env
chmod 600 single-server.env
```

至少填写单人邮箱登录、SMTP、`CAPABILITY_AUTH_CODE_PEPPER` 和至少一个文字模型密钥。默认模型由 `XIAOQI_DEFAULT_TEXT_MODEL` 选择，温度由 `XIAOQI_TEXT_TEMPERATURE` 控制；密钥只保存在服务器。

联网搜索和用户粘贴网页后的正文抓取使用 DeepSeek 原生 Search/Fetch API，服务器配置 `DEEPSEEK_API_KEY`；默认地址为 `https://api.deepseek.com/v1`，可用 `DEEPSEEK_SEARCH_BASE_URL` 覆盖。Search 只发送最短查询词并只引用接口返回的真实 URL 来源；未配置、接口失败或没有可验证来源时，会明确报告失败，不会切换服务商或伪造来源。官方原始 API 当前按成功请求计费（Search 与 Fetch 均为 5 元/千次），不要把“DeepSeek Harness / Claude Code / Codex 的服务端工具暂免”当作本应用原始 API 调用的免费额度。

要启用聊天中的图片生成，还要在服务器的 `single-server.env` 配置火山引擎 Ark `ARK_API_KEY`。默认图片模型为 Seedream 5.0 Lite（模型 ID：`doubao-seedream-5-0-260128`），API 地址可用 `ARK_IMAGE_API_URL` 覆盖。不要把密钥放进客户端或提交到仓库；未配置时，生图请求会返回“服务器未配置 ARK_API_KEY”。首次部署时，在服务器上生成沙箱执行器内部令牌：

```sh
sed -i "s/^SANDBOX_RUNNER_TOKEN=.*/SANDBOX_RUNNER_TOKEN=$(openssl rand -hex 32)/" single-server.env
```

令牌只保存在服务器的 `single-server.env`。`XIAOQI_PUBLIC_HOST` 设为已经指向这台 ECS 的域名；示例使用 `47-76-60-77.sslip.io`。密钥不返回 Flutter，也不要提交 `single-server.env`。

## 一键部署与自动恢复

在单人开发阶段，AI 修改了服务端代码、部署配置或客户端/服务端接口后，应在测试通过后自动运行下面的命令，不需要用户手动部署。只改 Flutter 界面、文档或测试时不部署：

```powershell
powershell -ExecutionPolicy Bypass -File .\xiaoqi_harness\deploy\deploy_current.ps1
```

这个命令保留为 AI 的标准入口和紧急手工入口。AI 必须根据实际代码差异判断是否需要部署，并在交付时明确说明“已部署并验证”或“不需要部署”及原因。

脚本先在后台构建新镜像，旧服务继续运行。构建成功后，它会保存上一版源码、镜像和数据，再切换到新版本；健康检查或数据核对失败时自动恢复上一版。成功后只保留当前运行版本和一份 `latest-good` 应急恢复点，旧镜像、旧备份和上传临时文件会被清理。服务器密钥始终留在 `/opt/xiaoqi-single-server/config/single-server.env`，不会打进发布包。

需要手工查看或恢复时，通过阿里云助手执行服务器上的固定脚本：

```sh
/opt/xiaoqi-single-server/release_manager.sh status
/opt/xiaoqi-single-server/release_manager.sh rollback
```

不要使用 `docker compose down -v`，它会删除业务数据卷。

Genkit 服务复用现有 `xiaoqi-data` 卷，SQLite 表结构及 `objects/` 文件布局保持一致，不复制或重写用户数据。Compose 只声明业务数据卷和 Caddy 证书卷。不要用 `docker compose down -v` 删除这些卷。代码执行镜像会在服务器构建；每个任务使用独立容器、临时卷和网络。默认网络关闭；用户为任务授权域名后，执行器才会创建该任务专属网络和 Squid 出口代理，代理只放行授权域名的 80/443 端口。任务结束或取消时会删除容器、代理、网络和临时卷。

沙箱容器使用非 root 用户、只读根文件系统、只挂载自己的任务卷、移除 Linux capabilities，并设置进程数、内存、CPU 和日志上限。Docker 容器仍共享 ECS 的 Linux 内核，隔离强度低于独立虚拟机；执行器的 Docker socket 权限等同于主机管理权限，因此不要把执行器端口公开给互联网或把 socket 挂载给 Dart API、MCP 或用户代码。

Agent 会话使用 `on`、`off` 两种联网模式；新会话和缺省值为 `off`，旧会话中的 `auto` 按 `off` 读取。开启时，Agent 只在事实请求需要实时资料时优先搜索，问候和纯创作不强制搜索。关闭时，普通聊天和普通代码执行不能联网；当前账号、技能版本均通过校验的技能，确需联网才能完成本任务时，可以为一次网页搜索或脚本 / Python 执行临时联网。搜索调用须带技能 ID 和用途；代码执行还须声明精确域名和用途。脚本域名仅传入本次执行创建的 Squid 代理，不写入任务的持久允许列表；该次执行结束或取消时，执行器清除临时容器、代理、网络与卷。手动切换会话开关时，API 先更新任务策略；切换到 `off` 会调用私有 runner 终止该任务正在运行的代理，并短暂记录拒绝状态，避免排队中的执行请求在关闭后重建代理。运行中的本地计算可以继续；若撤销失败，API 会返回服务错误并记录失败事件，不会报告撤销成功。

## 验证与故障恢复

目标服务器应验证 `/health`、邮箱登录、连续聊天与流式事件、任务取消/恢复、技能云同步和草稿冲突、MCP 登录鉴权，以及容器重启后的数据读取。笔记分析、图片笔记分析、文字改写和会话标题通过带邮箱会话鉴权的 `/v1/chat/completions` 进入 Genkit；模型密钥与默认文字模型只从服务器环境读取。代码执行还应验证 Python、JavaScript、TypeScript、默认断网、未授权域名被拒、已授权域名可访问、取消后资源清理和产物下载；沙箱无需第三方账号或服务密钥。图片生成验收推迟到本次架构迁移完成后。

每次成功部署后只保留一份 `latest-good`。手工执行 `release_manager.sh rollback` 会停止当前服务，恢复上一版源码、四个业务镜像和升级前数据，再重新执行健康检查。这个机制处理“新代码或新镜像部署失败”；如果整台 ECS 或云盘损坏，仍需阿里云磁盘快照等异机备份，项目脚本无法从已经丢失的磁盘自行恢复。

## 参考资料

| 来源 | 查阅时间 | 用途 |
| --- | --- | --- |
| [Genkit Dart Agents](https://genkit.dev/docs/dart/agents/overview/) | 2026-10-09 | Dart Agent API；Beta API 固定版本并由 `XiaoqiAgentRuntime` 隔离 |
| [Genkit Dart middleware](https://genkit.dev/docs/dart/middleware/) and [source](https://github.com/genkit-ai/genkit-dart) | 2026-10-11 | `genkit_middleware 1.0.0`（Apache-2.0）；复用官方 Skills middleware 与 `use_skill` 按需加载，不复制技能运行框架 |
| [Genkit A2UI](https://genkit.dev/docs/agents/a2ui/) and [Flutter GenUI](https://github.com/flutter/genui) | 2026-10-11 | `genkit_a2ui 0.4.0`（Apache-2.0）、`genui 0.10.4`（BSD-3-Clause）、`a2ui_core 0.1.1`（Apache-2.0）；复用官方 middleware、受限目录、`SurfaceController` 和 action 消息 |
| [DeepSeek 网页搜索与抓取](https://api-docs.deepseek.com/zh-cn/guides/search/) | 2026-10-17 | 按官方 Search/Fetch 原始 JSON 契约接入；自动化契约测试覆盖请求字段、正文和真实 URL 来源校验 |
| [Genkit Dart on pub.dev](https://pub.dev/packages/genkit/versions) | 2026-10-09 | Genkit 1.0.0 与 Dart SDK 版本约束 |
| [Genkit MCP Dart](https://pub.dev/documentation/genkit_mcp/latest/) | 2026-10-09 | 服务端 MCP tools、resources 与 prompts |
| [Docker Compose volumes](https://docs.docker.com/reference/compose-file/volumes/) | 2026-10-09 | 命名卷持久化行为 |
| [Docker Engine security](https://docs.docker.com/engine/security/) | 2026-10-10 | Docker socket 权限与容器隔离边界 |
| [Docker resource constraints](https://docs.docker.com/engine/containers/resource_constraints/) | 2026-10-10 | 沙箱内存与 CPU 限制 |
| [Squid `http_access`](https://www.squid-cache.org/Doc/config/http_access/) | 2026-10-10 | 每个任务的域名访问控制 |
