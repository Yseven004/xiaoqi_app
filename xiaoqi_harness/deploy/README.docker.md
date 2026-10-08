# 小七单机 Docker 部署

## 当前配置

- `app` 容器包含 Flask API、ACP 适配代码和固定版本 `@deepseek-ai/dsh@0.2.0-rc.2`；只运行一个 Gunicorn worker 和一个后台任务 worker。它以只读方式挂载 DSH 运行包卷。
- `dsh-manager` 是独立的非 root 管理服务，提供简洁的插件页和版本管理页；管理器独占写入 DSH 运行包卷，生产 app 不能修改已发布的程序或配置。
- SQLite 与对象文件位于 `/var/lib/xiaoqi`，由命名卷 `xiaoqi-data` 持久化。重建容器会复用该卷；`docker compose down -v` 会删除它。
- app 与管理器均不发布宿主机端口。Caddy 在 `https` profile 中单独启动，只发布 80/443；`caddy-data` 和 `caddy-config` 保存证书状态。小七和管理后台使用不同域名。
- 起始资源上限为 1.5 GiB 内存和 1.5 CPU，留出 ECS 系统与 Caddy 的余量；真实 DSH 对话的内存占用留到服务器运行时记录。
- `/run/xiaoqi` 仅为 DSH 原生组件缓存启用可执行映射，内容随容器重建清空；`/tmp` 显式保持 `noexec`。
- 密钥从宿主机 `single-server.env` 注入。该文件被 Git 和 Docker build context 忽略，不复制进镜像。服务器上应限制为仅管理员可读。

## 构建和启动应用

在 `xiaoqi_harness/deploy` 目录执行：

```sh
cp single-server.env.example single-server.env
chmod 600 single-server.env
docker compose build app
docker compose up -d app
docker compose ps
docker compose exec app dsh --version
```

为后台生成内部访问令牌和管理员密码哈希。令牌只保存在服务器环境文件；密码通过隐藏输入，不会写入命令历史：

```sh
openssl rand -hex 32
docker compose --env-file ./single-server.env build dsh-manager
docker compose --env-file ./single-server.env run --rm --no-deps dsh-manager python -c "from getpass import getpass; from werkzeug.security import generate_password_hash; print(generate_password_hash(getpass('新管理员密码: ')))"
```

将第一条命令输出写入 `XIAOQI_DSH_INTERNAL_TOKEN`，将第二条命令输出写入 `XIAOQI_DSH_ADMIN_PASSWORD_HASH`。在 `single-server.env` 中填好登录邮件、SMTP、pepper、模型 API 和令牌；设置 `XIAOQI_ADMIN_HOST` 为已解析到此服务器的管理域名。随后构建并启动服务：

```sh
docker compose --env-file ./single-server.env build app dsh-manager
docker compose --env-file ./single-server.env up -d app dsh-manager
XIAOQI_PUBLIC_HOST=47-76-60-77.sslip.io docker compose --env-file ./single-server.env --profile https up -d caddy
docker compose --env-file ./single-server.env ps
```

把 `XIAOQI_PUBLIC_HOST` 和 `XIAOQI_ADMIN_HOST` 都设为各自的公网域名，并确保 DNS 指向服务器后，Caddy 会分别代理到小七 API 和 DSH 管理后台。管理后台只接受预先设置的管理员密码，没有公开注册入口。密码哈希或内部令牌为空时应视为部署配置未完成，不要开放管理域名。

## 重建容器后的持久化检查

以下命令在数据卷里分别写入一个 SQLite 检查值和一个文件，重建 `app` 容器后验证两者仍存在，再清理检查文件：

```sh
docker compose exec app python -c "import sqlite3; c=sqlite3.connect('/var/lib/xiaoqi/.compose-persist-check.sqlite3'); c.execute('create table if not exists check_data(value text)'); c.execute('insert into check_data values (?)', ('persisted',)); c.commit()"
docker compose exec app python -c "from pathlib import Path; Path('/var/lib/xiaoqi/.compose-persist-check').write_text('persisted')"
docker compose up -d --force-recreate app
docker compose exec app python -c "import sqlite3; from pathlib import Path; assert sqlite3.connect('/var/lib/xiaoqi/.compose-persist-check.sqlite3').execute('select value from check_data order by rowid desc limit 1').fetchone()==('persisted',); assert Path('/var/lib/xiaoqi/.compose-persist-check').read_text()=='persisted'; print('SQLite and files persisted')"
docker compose exec app python -c "from pathlib import Path; Path('/var/lib/xiaoqi/.compose-persist-check.sqlite3').unlink(missing_ok=True); Path('/var/lib/xiaoqi/.compose-persist-check').unlink(missing_ok=True)"
```

## 参考与取舍

| 来源 | 版本/日期与许可 | 用途 |
|---|---|---|
| [DeepSeek Harness v0.2.0-rc.2 release](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.0-rc.2) | 2026-09-29；上游仓库 MIT | 固定 DSH CLI 版本 |
| [上游 package.json](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.0-rc.2/package.json) | `dsh-v0.2.0-rc.2`；MIT；Node `^22.19.0` 或 `>=24.0.0` | 选择 Node 22 容器基底 |
| [Docker Compose named volumes](https://docs.docker.com/reference/compose-file/volumes/) | 官方文档，查阅于 2026-10-08 | SQLite、对象文件和 Caddy 证书使用命名卷 |
| [Docker Compose environment practices](https://docs.docker.com/compose/how-tos/environment-variables/best-practices/) | 官方文档，查阅于 2026-10-08 | 密钥仍由服务端环境配置提供；文件不进入镜像构建上下文 |
| [Caddyfile environment variables](https://caddyserver.com/docs/caddyfile/concepts#environment-variables) | 官方文档，查阅于 2026-10-08 | Caddy 使用 Compose 注入的站点地址 |

Compose `env_file` 保持当前 API 的环境变量配置方式；Docker 官方建议高敏感值优先使用 secrets。切换到文件型 secrets 需要应用读取 `*_FILE` 配置，列为后续安全加固，不影响本轮镜像中不包含密钥。
