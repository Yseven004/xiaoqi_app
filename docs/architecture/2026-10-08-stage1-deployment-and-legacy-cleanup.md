# 小七第一阶段部署状态与旧资源清理（2026-10-08）

## 当前技术框架

| 环节 | 当前状态 | 证据与边界 |
|---|---|---|
| ECS 与系统盘 | 香港 ECS `i-j6cdji1nji415swaliji` 运行中，2 vCPU / 2 GiB；40 GiB ESSD Entry 系统盘挂载中；按量付费 | 2026-10-08 只读查询；公网 IP 为 `47.76.60.77` |
| 小七 API 与 DSH | 同一 ECS 应用容器；DSH 固定为 0.2.0-rc.2 | 平板已通过新服务登录、发消息并收到 DSH 回答 |
| HTTPS | Caddy 独立容器，公网入口为 80/443 | 2026-10-08 对 https://47-76-60-77.sslip.io/health 的只读检查返回 HTTP 200、证书校验成功 |
| ECS 安全组 | 80/443 对公网开放；8080 未开放 | 另有 TCP 22、TCP 3389 和 ICMP 对 `0.0.0.0/0` 放行；建议关闭不需要的 3389，并将 SSH 来源限制为管理 IP；本次只读盘点未改规则 |
| 持久化 | ECS Docker 数据卷中的 SQLite 与私有文件目录 | 容器重建后数据保留已验证；当前阶段无需 PostgreSQL 或 MinIO |
| App 能力 API | 已部署测试版使用 ECS；本机 `api_config.dart` 默认地址已改为 https://47-76-60-77.sslip.io/v1 | 旧测试版 APK 若仍指向 FC，删除旧函数后会失效 |
| 任意代码执行 | 当前不开放 Python、TypeScript、JavaScript 或 Docker 沙箱 | 隔离验证属于后续阶段；安装运行环境不等于开放执行能力 |

`lib/config/api_config.dart` 被 `.gitignore` 忽略。以后构建测试版时应显式传入 `--dart-define=CAPABILITIES_BASE_URL=https://47-76-60-77.sslip.io/v1`，以免在另一台开发机使用旧默认地址。

第一阶段的真实平板对话链路已验证。尚未实际关掉开发电脑进行专项验收；服务器部署本身不依赖开发电脑。任务结束后 24 小时清理已用回拨时间的过期测试记录验证后台清扫，没有等待完整 24 小时。

## 2026-10-08 清理决定

用户确认旧 FC、Tablestore 和 OSS 中的数据均为可丢弃的开发测试数据，无需备份或迁移。旧 APK 的兼容性不作为保留旧能力 API 的条件。书籍扫描服务继续保留。用户授权助手用阿里云 CLI 清理明确属于小七旧测试链路的资源。

| 资源 | 当前依赖 | 处置 |
|---|---|---|
| FC `xiaoqi_capability_api` | 旧测试版能力 API；新 App 能力 API 已接入 ECS | 2026-10-08 已用 CLI 删除函数与 HTTP 触发器；旧测试版 APK 的登录、技能与任务请求可能失效 |
| FC `xiaoqi_sandbox` | 旧任务 Worker；新对话由 ECS 中的 DSH 处理 | 2026-10-08 已用 CLI 删除函数与 HTTP 触发器；当前没有运行中任务 |
| Tablestore 实例 `b02dh2iy3b1d`（别名 `xiaoqi-capabilities`） | 旧 API 和 Worker 环境变量引用 | 已关闭续费；账单状态为已过期，实例状态为 `forbidden`，到期后已停止计费。尝试立即释放被服务端拒绝；按官方规则，过期停服 15 天后自动释放实例及数据（预计 2026-10-23 02:54 UTC） |
| OSS 桶 `xiaoqi-capabilities-20261004-a1` | 旧 API 和 Worker 环境变量引用 | 当前账号查询返回 `NoSuchBucket`，已不存在；本轮没有删除任何对象 |
| 三个 `e2b-sandbox-template-*` FC 函数 | 旧 E2B 沙箱模板；当前 ECS 配置未注入 E2B 凭据，代码执行关闭 | 用户明确指示删除；2026-10-08 三个函数均由 CLI 删除成功，随后函数清单只剩书籍代理 |
| FC `xiaoqi-isbn-proxy` | 探数书籍代理 | 函数仍在杭州 FC 清单中并保留；迁到 ECS 并验证扫码查书后再考虑删除 |
| App 默认的 `book-reion-fast-dmjshckoxv.ap-southeast-1.fcapp.run` | 书籍识别与查询入口；不在当前阿里云账号的新加坡 FC 清单中 | 未删除；需确认归属与实际扫码功能。杭州 `xiaoqi-isbn-proxy` 是 GET 代理，不可直接替代 App 使用的 POST 识别接口 |
| App 中的 `deepseek-proxy-txphvsfbua.cn-hangzhou.fcapp.run` | `AiService` 仍用于标题、笔记等 AI 功能；未对应到本账号已列出的杭州 FC 函数 | 保留；完成该调用链迁移后再删除对应服务 |

三个 E2B 模板函数的准确名称：

- `e2b-sandbox-template-0656d71668-codeinte-8020d110-a3a9-489c-b59b-64d7f139b0ae`
- `e2b-sandbox-template-203496e3-b5bf-4497-9804-73304afe5fdf`
- `e2b-sandbox-template-951f2ee6-8bb9-4741-afdd-8225fdca0fc1`

杭州 FC 清理后的只读清单中剩下三个 E2B 模板函数和 `xiaoqi-isbn-proxy`。书籍代理的环境变量仅包含探数接口和代理令牌，未挂载 OSS、未配置访问 Tablestore 的角色；已删除的旧能力 API 和 Worker 曾配置 OTS 与 OSS 变量。三个 E2B 模板函数没有旧 OSS 挂载或 OTS/OSS 环境变量。

## 清理结果与后续动作

1. 旧能力 API 与旧 Worker 已删除；OSS 桶已不存在。新 App 仍通过 ECS 完成 HTTPS 登录与 DSH 对话。
2. Tablestore 已过期且不续费，停止服务并停止计费；直接删除因 `forbidden` 状态被拒绝，将按 15 天到期释放机制自动清除。
3. 三个 E2B 模板函数已按用户明确指示删除；复查杭州 FC 清单时均已消失。
4. 书籍 ISBN 代理与书籍扫描入口均未由本次操作删除。当前账号可见的杭州代理仍在；App 配置的新加坡识别入口不在当前账号该地域清单中，扫描链路仍需单独查明和验证。
5. 模型代理仍被 `AiService` 调用，保持不动。

ECS 的 `xiaoqi-single-server` 应用、Caddy 容器及其数据卷属于现行服务，不在上述旧资源清单中。

## 2026-10-08 阿里云资源中心盘点

资源中心已开通。只读资源计数共 23 条：

- 香港：1 台 ECS、1 块 40 GiB 系统盘、1 个网卡、1 个安全组、1 个 VPC、1 个交换机和 1 个路由表。
- 函数计算：杭州 1 个函数和 1 个触发器（`xiaoqi-isbn-proxy`）；新加坡 0 个函数。旧能力 API、旧 Worker 和三个 E2B 模板均不在当前清单中。
- Tablestore：杭州 1 个已过期且状态为 `forbidden` 的 VCU 实例，等待到期释放。
- OSS：当前账号桶列表为 0。
- 其他账号级资源：北京 1 个 Model Studio 默认业务空间；RAM 下有 10 个角色、1 个用户 `xiaoqi-harness-deployer` 和 1 个自定义策略 `XiaoqiCapabilityStorageAccess`。本次仅盘点，未改动这些身份资源；删除前需确认其关联对象和 CLI 部署用途。

资源中心只覆盖其支持并已纳管的资源类型；本次清单覆盖了小七当前部署涉及的云产品。App 代码仍引用的书籍新加坡入口与 DeepSeek 代理没有对应到当前资源中心/FC 函数清单，分别保持未删除并待定位。
