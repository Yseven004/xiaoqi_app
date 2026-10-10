# 小七 Genkit Dart 单机部署

当前部署包含 Dart API、私有 Docker 沙箱执行器和 Caddy。Dart 服务提供兼容 Flutter 的 HTTP API，并在容器内提供 Genkit MCP；Caddy 负责公开 HTTPS、转发 API，并在转发 `/mcp` 前检查现有单人登录会话。沙箱执行器只在服务器内部接收任务，唯一能访问 Docker socket 的是这个受限执行器；用户代码容器不会拿到 socket 或主机目录。没有管理后台，模型、邮件、图片和沙箱配置全部从服务器环境变量读取。

Flutter 继续使用原有 HTTP 协议，不需要升级 Flutter 或添加 Genkit Flutter 客户端依赖。技能和草稿的本地数据仍由 Flutter 保存；服务端保留已有云端同步 API 与 SQLite 文档/对象格式。

## 服务器配置

在服务器进入 `xiaoqi_harness/deploy`，复制示例并编辑仅存于服务器的文件：

```sh
cp single-server.env.example single-server.env
chmod 600 single-server.env
```

至少填写单人邮箱登录、SMTP、`CAPABILITY_AUTH_CODE_PEPPER` 和至少一个文字模型密钥。默认模型由 `XIAOQI_DEFAULT_TEXT_MODEL` 选择，温度由 `XIAOQI_TEXT_TEMPERATURE` 控制；密钥只保存在服务器。图片生成模型与 `ARK_API_KEY` 暂不作为本次迁移验收项，等架构迁移完成后再配置。首次部署时，在服务器上生成沙箱执行器内部令牌：

```sh
sed -i "s/^SANDBOX_RUNNER_TOKEN=.*/SANDBOX_RUNNER_TOKEN=$(openssl rand -hex 32)/" single-server.env
```

令牌只保存在服务器的 `single-server.env`。`XIAOQI_PUBLIC_HOST` 设为已经指向这台 ECS 的域名；示例使用 `47-76-60-77.sslip.io`。密钥不返回 Flutter，也不要提交 `single-server.env`。

## 备份、构建与启动

在目标服务器执行以下步骤。先构建新镜像，再停止 API 并备份数据：

```sh
cd xiaoqi_harness/deploy
mkdir -p backups
docker compose --env-file ./single-server.env build app sandbox-runner
docker compose --env-file ./single-server.env --profile build-only build sandbox-image sandbox-proxy-image
docker compose --env-file ./single-server.env stop app
docker run --rm -v xiaoqi-single-server_xiaoqi-data:/data:ro -v "$PWD/backups:/backup" alpine:3.22 sh -c 'tar -czf /backup/xiaoqi-data-before-genkit.tgz -C /data .'
docker run --rm -v xiaoqi-single-server_xiaoqi-data:/data:ro -v "$PWD:/deploy:ro" -v "$PWD/backups:/backup" python:3.12-slim python /deploy/verify_store.py --root /data --output /backup/genkit-before.json
docker compose --env-file ./single-server.env --profile https up -d --remove-orphans app sandbox-runner caddy
docker compose --env-file ./single-server.env ps
curl --fail https://47-76-60-77.sslip.io/health
docker run --rm -v xiaoqi-single-server_xiaoqi-data:/data:ro -v "$PWD:/deploy:ro" -v "$PWD/backups:/backup" python:3.12-slim python /deploy/verify_store.py --root /data --output /tmp/genkit-after.json --compare /backup/genkit-before.json
```

Genkit 服务复用现有 `xiaoqi-data` 卷，SQLite 表结构及 `objects/` 文件布局保持一致，不复制或重写用户数据。Compose 只声明业务数据卷和 Caddy 证书卷。不要用 `docker compose down -v` 删除这些卷。代码执行镜像会在服务器构建；每个任务使用独立容器、临时卷和网络。默认网络关闭；用户为任务授权域名后，执行器才会创建该任务专属网络和 Squid 出口代理，代理只放行授权域名的 80/443 端口。任务结束或取消时会删除容器、代理、网络和临时卷。

沙箱容器使用非 root 用户、只读根文件系统、只挂载自己的任务卷、移除 Linux capabilities，并设置进程数、内存、CPU 和日志上限。Docker 容器仍共享 ECS 的 Linux 内核，隔离强度低于独立虚拟机；执行器的 Docker socket 权限等同于主机管理权限，因此不要把执行器端口公开给互联网或把 socket 挂载给 Dart API、MCP 或用户代码。

## 验证与故障恢复

目标服务器应验证 `/health`、邮箱登录、连续聊天与流式事件、任务取消/恢复、技能云同步和草稿冲突、MCP 登录鉴权，以及容器重启后的数据读取。笔记分析、图片笔记分析、文字改写和会话标题通过带邮箱会话鉴权的 `/v1/chat/completions` 进入 Genkit；模型密钥与默认文字模型只从服务器环境读取。代码执行还应验证 Python、JavaScript、TypeScript、默认断网、未授权域名被拒、已授权域名可访问、取消后资源清理和产物下载；沙箱无需第三方账号或服务密钥。图片生成验收推迟到本次架构迁移完成后。

升级前的压缩备份用于恢复 SQLite 与对象文件。需要恢复时，先停止 `app`，将备份解压回 `xiaoqi-data` 卷，再启动服务；恢复会覆盖同名文件，执行前先另存当前卷备份。新镜像使用部署步骤里的命令重建；Caddy 的证书数据仍在 `caddy-data` 与 `caddy-config` 卷中。

## 参考资料

| 来源 | 查阅时间 | 用途 |
| --- | --- | --- |
| [Genkit Dart Agents](https://genkit.dev/docs/dart/agents/overview/) | 2026-10-09 | Dart Agent API；Beta API 固定版本并由 `XiaoqiAgentRuntime` 隔离 |
| [Genkit Dart on pub.dev](https://pub.dev/packages/genkit/versions) | 2026-10-09 | Genkit 1.0.0 与 Dart SDK 版本约束 |
| [Genkit MCP Dart](https://pub.dev/documentation/genkit_mcp/latest/) | 2026-10-09 | 服务端 MCP tools、resources 与 prompts |
| [Docker Compose volumes](https://docs.docker.com/reference/compose-file/volumes/) | 2026-10-09 | 命名卷持久化行为 |
| [Docker Engine security](https://docs.docker.com/engine/security/) | 2026-10-10 | Docker socket 权限与容器隔离边界 |
| [Docker resource constraints](https://docs.docker.com/engine/containers/resource_constraints/) | 2026-10-10 | 沙箱内存与 CPU 限制 |
| [Squid `http_access`](https://www.squid-cache.org/Doc/config/http_access/) | 2026-10-10 | 每个任务的域名访问控制 |
