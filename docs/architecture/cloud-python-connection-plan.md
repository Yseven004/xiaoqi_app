# 小栖 V1：云端与 Python 接通方案

日期：2026-10-03；登录方案更新于 2026-10-05。状态：分阶段实施中；个人邮箱登录已完成本地代码实现，尚未部署到真实云函数。

## 当前状态与目标

用户已确认纯文字技能的创建、试用、保存、再次调用闭环成功。保留这条已验证路径。

仓库已有配对、技能同步、任务接口、工具循环和沙箱调用。已补任务请求去重、worker 租约、Python 产物转存和鉴权下载；任务 ID 现在随本地会话持久化，切换会话不会取消云端运行，重新打开未完成会话可接回事件。Python 沙箱现选用阿里云 Agent Sandbox 极速版（杭州）；用户已创建测试 Team 和 API Key，密钥尚未写入任何文件或聊天。E2B 精确锁定版本的 Python wheel 已核对 `network`、文件读取及图像/PDF 结果接口；联网执行现按批准域名配置出站 allowlist，并拒绝其余出站流量。

函数拆分：现有 `fc_proxy_function.py` 继续承载聊天代理与技能 API；新增 `fc_agent_worker_function.py` 只承载异步任务运行和沙箱取消。Agent Sandbox API Key、Endpoint 和 domain 只配置在 worker 函数。两个函数共享所需的 Tablestore、私有 OSS 和内部任务凭证。

云端只读盘点无法通过：本机阿里云 CLI 配置的密钥被 FC API 返回 `InvalidAccessKeyId.NotFound`。未执行任何云资源写入；函数、OSS、Tablestore 和 E2B 的真实端到端状态仍待有效凭证后核验。联网确认、任务结果和产物卡片的黑白轻量状态预览已生成；新 UI 接入等用户确认该预览后进行。

本阶段成功标准：同一身份的两台设备可以同步技能；需要 Python 的技能自动执行，并在对话中返回真实结果及可下载产物；停止、断网、重试和服务异常不会丢失已保存技能或重复执行任务。

## 推荐架构

Flutter → 阿里云 FC 能力 API → Tablestore 元数据 / 私有 OSS 文件。

能力 API 函数 → 独立 FC 异步 worker → 当前所选模型的工具循环 → 阿里云 Agent Sandbox Python → OSS 产物 → 对话结果。

复用现有 Python 服务与已选 SDK：`e2b-code-interpreter==2.10.1`、`e2b==2.52.0`。杭州连接参数通过服务端环境变量传入：`E2B_API_KEY`、`E2B_API_URL=https://api.cn-hangzhou.sandbox.aliyuncs.com`、`E2B_DOMAIN=cn-hangzhou.sandbox.aliyuncs.com`。已核对这两个锁定 wheel 中代码解释器沙箱继承的网络参数，以及 sandbox 文件与图像/PDF 结果读取接口；实际网络规则仍需在 Agent Sandbox 中完成联调验证。

设备只持有可撤销设备凭证；模型、E2B、OSS 凭证留在服务端。优先采用 FC 执行角色获取短期云凭证，需补齐凭证刷新支持。OSS 不开放公开读写。

## 1. 盘点环境并冻结新增状态

读取现有部署描述，确认阿里云地域、FC 函数/运行时、HTTP 入口、OSS 和 Tablestore 是否已存在；只报告配置项是否存在，不输出密钥。列出复用资源、需新增资源和费用控制项。先准备可审阅的部署配置与回滚步骤，再执行云端变更。

新增 UI 沿用已确认的黑白轻量风格。需补齐的状态：未登录/会话失效、待同步/冲突、Python 执行中/失败、联网用途与域名确认、文件下载成功/失败。联网选择面板在输入框上方；结果在消息内展示，下载操作不使用全屏弹窗。页面加载使用静态占位。

交付：环境缺项清单、部署配置草稿、上述状态的静态预览；新增状态完成视觉确认后再实现。无需重做已冻结的主菜单。

## 2. 接通个人账号和云同步

配置私有 OSS、Tablestore 条件写入和 FC 身份权限；个人账号通过邮箱验证码创建可撤销会话，验证验证码过期、重发限流、错误尝试限制、会话恢复和退出撤销。客户端会话凭证保存在系统安全存储。

首次登录后上传现有本地技能和草稿，保留稳定 ID、不可变版本及内容校验值；正式保存仍只能由用户操作触发。服务器校验资源归属和内容摘要，展示偏好按已确认的数据模型同步。冲突保留双方版本并提供明确处理入口；删除标记阻止离线旧设备复活内容。

断网时本地操作继续，显示待同步；重新连接后重试。不因同步失败清空本地数据。将能力服务地址配置纳入可复现的构建流程，避免依赖被 Git 忽略的本机配置。

验收：个人账号登录后不保存技能也能从首页启动 Agent；设备 A 保存后，设备 B 使用同一个人账号登录即可调用；A 隐藏后仍可自动发现；两设备同时修改保留冲突；删除后离线旧设备上线不会重新上传；退出并撤销会话后该会话无法访问云资源。

## 3. 接通真实 Python 与产物

先验证 FC 到模型服务和 E2B 的实际连通性。纯文字请求不创建沙箱；需要 Python 时后台直接执行。显式选择技能优先，自动发现目录提供能力 ID、版本和资源引用，避免工具无法定位技能。

只上传本次任务资料及实际需要的技能文件。补齐新建草稿的脚本与资源传入，确保创建阶段的试用也能运行 Python。附件采用受归属校验的私有对象引用，统一接口与 worker 的大小限制。

脚本将产物写入 `/home/user/workspace/output`；后台在销毁沙箱前读取常规文件和 PNG/JPEG/PDF 结果，上传私有 OSS，再发送产物事件。事件包含产物 ID、文件名、类型、大小、摘要；下载接口校验设备与任务归属后由服务端流式返回文件，并校验 SHA-256，不生成预签名链接。拒绝越界路径和符号链接逃逸，最多返回 10 个文件，每个不超过 10 MB，总量不超过 20 MB。上述限额当前为代码常量；OSS 生命周期/产物保留期限尚未配置。

正确处理 Python 执行错误，不能把异常或空结果报告为成功。当前执行上限为 120 秒、沙箱寿命 300 秒、文本输出上限 128 KB；文件数量与体积上限采用上述代码常量，部署前应结合个人用量核定 OSS 保留期限和费用控制。当前每任务最多一次 Python 调用；超时后结果不明时不自动重跑。

验收：上传一份小 CSV，自动计算分类汇总，生成汇总 CSV 和 PNG 图表；对话能显示结果，文件下载后内容一致；重新打开对话仍能获取产物。此用例不要求开放“绘图”内置入口。

## 4. 补齐取消、恢复和联网边界

FC 异步投递可能重试。以任务 ID 做请求去重，再以 attempt、执行租约及工具调用 ID 防止两个 worker 同时执行。FC 的请求 ID 不能替代业务幂等。工具执行前后持久化状态；结果未知时不盲目重跑，明确返回可恢复或需重新发起的状态。

事件带递增序号，客户端按游标重连；恢复继续读取现有任务。取消先标记服务端任务，再停止后续模型/工具调用并清理沙箱；取消后迟到结果不能覆盖终态。失败清理需要可重试记录与到期兜底，不能仅吞掉 kill 异常。

沙箱默认禁网。模型提出联网需求时展示用途和精确域名，用户允许后才继续；E2B 网络配置同时拒绝默认出站并只放行获准域名。真实沙箱仍需验证允许域名、未允许域名及重定向边界。授权只覆盖当前任务，不弹出 Python 执行确认。

验收：运行中停止后不再调用工具；重复提交不重复执行；应用重启能恢复事件；断网重连无重复消息；沙箱超时和 E2B 故障可识别，纯文字能力继续可用。

## 5. 分层交付与回滚

分别记录代码完成、自动检查、真实云端联调、同状态视觉对比、用户真机验收、已部署。完成其中一层不代称其他层通过。按用户要求不使用 ARTEMIS。

日志使用任务 ID 关联 API、模型和沙箱，记录耗时、终态和错误类别；避免记录原始资料与凭证。配置请求频率、并发和沙箱执行上限；预算阈值需在真实账户信息明确后确定，不凭空估算费用。

先在测试入口验证，再切换能力服务地址。保留上一部署版本，出现问题可关闭云端能力入口并回滚服务；本地技能、草稿、云端版本及删除标记不做破坏性迁移。E2B 不可用时明确反馈 Python 不可执行，保持纯文字流程可用。

最终演示顺序：两设备同步一个已保存技能 → CSV 汇总与文件回传 → 取消与恢复 → 冲突和删除 → Python 故障时纯文字仍可用。

## 执行前需要补齐的信息

优先从现有项目配置读取阿里云部署信息，读取不到再请用户提供函数名称或控制台位置。当前 CLI 身份已失效，FC 返回 `InvalidAccessKeyId.NotFound`；刷新本机阿里云凭证后才能继续只读盘点与真实云端联调。E2B Key 和云密钥仅通过服务端配置填入，不通过聊天发送。新增资源规格、产物保留期限和费用上限在部署配置审阅时一并确认。

下一步：确认云端状态预览；刷新阿里云 CLI 凭证；随后继续资源复核和 FC/OSS/Tablestore/E2B 联调。

## 官方参考（2026-10-03 核对）

- [阿里云 FC HTTP Trigger Overview](https://www.alibabacloud.com/help/en/functioncompute/http-triggers-overview)：支持异步请求和任务 ID；异步接收响应不等于任务成功。
- [阿里云 FC Asynchronous invocation](https://www.alibabacloud.com/help/en/functioncompute/fc-asynchronous-invocation)：异步执行包含平台重试，需应用层去重。
- [阿里云 Agent Sandbox 极速版 SDK 接入](https://help.aliyun.com/zh/agent-sandbox/getting-started/using-the-cloud-sandbox-via-the-sdk)：确认 E2B SDK 的 API Key、杭州 Endpoint 和 domain 环境变量。
- [阿里云 FC Web 函数创建](https://help.aliyun.com/zh/functioncompute/creating-a-web-function)：Python Flask Web 函数可通过 ZIP 代码包部署。
- [阿里云 FC HTTP 触发器](https://help.aliyun.com/zh/functioncompute/http-triggers-overview)：确认请求级异步调用和任务 ID 请求头。
- [E2B Download data from sandbox](https://docs.e2b.dev/filesystem/download)：文件可通过 files.read 取回；本方案在沙箱清理前转存 OSS。
- [E2B Python SDK 网络配置](https://github.com/e2b-dev/e2b/blob/main/packages/python-sdk/e2b/sandbox/sandbox_api.py)：核对精确锁定 wheel，确认 `allow_out`/`deny_out` 支持域名出站规则；实际隔离效果仍待真实沙箱联调。

以上为文档参考，未复制第三方代码；本方案不改变既有 Skill Creator 来源与许可证记录。

## 2026-10-05 账号登录实现与开源参考

### 已确认范围

- 不接 Supabase 或 Firebase 身份服务；阿里云现有 API 与 Tablestore 继续保存个人账号会话。
- 使用 QQ 邮箱验证码；只有服务端配置的个人邮箱可以登录。SMTP 授权码只保存在阿里云函数环境变量中，不进入聊天、Flutter 或仓库。
- 登录页按“邮箱 → 获取验证码 → 输入验证码 → 登录”工作；首页及现有聊天布局保留。旧 Flutter 配对调用已移除，服务端旧配对接口仅保留兼容和回退用途。
- 登录成功后自动尝试同步技能和草稿；失败不阻止发送普通 Agent 任务。已有本地会话可离线查看本地内容。

### 开源登录组件评估

| 来源 | 核查版本、日期、许可证 | 评估与取舍 |
| --- | --- | --- |
| [NearHuscarl/flutter_login](https://github.com/NearHuscarl/flutter_login) / [pub.dev](https://pub.dev/packages/flutter_login/versions) | `flutter_login` 7.0.0；2026-10-05 核查时 pub.dev 显示约 3 个月前发布；MIT | 有可定制登录组件和验证码确认回调，但主登录表单包含邮箱/密码，验证码确认用于注册和密码找回。个人邮箱 OTP 登录仍需重写表单状态，默认动画卡片也不符合保留现有页面的决定。因此仅参考回调设计，不直接引入依赖或复制代码。 |
| [FirebaseUI-Flutter](https://github.com/firebase/FirebaseUI-Flutter) | 核查 `main` README；Apache-2.0；2026-10-05 | 官方组件连接 Firebase Authentication，邮件流程是密码或邮件链接；接入会改变当前阿里云账号边界，因此不采用。 |

本次没有复制第三方实现；当前登录页和邮箱 OTP API 是小范围项目内实现。

### 本地实现和未完成项

- 已完成：独立邮箱登录页、应用启动时恢复会话、QQ SMTP 验证码接口、验证码有效期/重发冷却/尝试限制、退出撤销、首页按个人邮箱会话走 Agent、管理面板同步与退出。
- 自动检查：API 与认证测试 29 项通过；所改 Flutter 文件 `flutter analyze` 无问题；健康检查本地返回 HTTP 200。代码实现和本地检查不代表已经部署或真机验证。
- 尚未部署：现有 API 函数需部署包含新路由的代码，并在 Function Compute 配置 `CAPABILITY_OWNER_EMAIL`、`CAPABILITY_SMTP_USERNAME`、`CAPABILITY_SMTP_PASSWORD`、`CAPABILITY_AUTH_CODE_PEPPER` 和 `CAPABILITY_API_RELEASE_ID`。QQ SMTP 授权码只在云端配置，不通过聊天发送。部署后用 `/health` 的 `release_id` 核对代码版本，再用真实邮箱完成登录与首页任务验收。
- 未完成：真机登录、验证码邮件送达、云端会话持久化/撤销、首次技能和草稿同步以及部署版本核对。
