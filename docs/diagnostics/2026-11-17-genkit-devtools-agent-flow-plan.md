# Genkit Developer UI 小栖 Agent 调试入口方案

日期：2026-11-17
目标：Agent 链路问题优先在 Genkit Developer UI 中复现和观察，不启动 Flutter App。

## 能力映射

| 需求 | 锁定版本官方 API / 源码 | 当前接入 | 复用 / 适配 / 移除 | 具体缺口 | 状态所有者 |
| --- | --- | --- | --- | --- | --- |
| 在 Developer UI 跑小栖实际 Agent 链路 | 服务端/客户端均锁定 Genkit 1.0.2；官方稳定 `Genkit.defineFlow`：`D:/dev/pub-cache/hosted/pub.dev/genkit-1.0.2/lib/src/genkit_class.dart:154`；官方 Agent 客户端 `remoteAgent`、`AgentChat.sendStream`：同版本 `lib/src/ai/agents/agent_core.dart:742` 与 `experimental_client.dart` | Flutter 通过 `remoteAgent` 调 `/v1/agent/chat`；服务端 `XiaoqiApi` 注册 `defineCustomAgent` 和 `contextProvider`，`api.dart:346-355` | 增加仅用于开发工具的 Flow 包装，仍调用原 `/v1/agent/chat` 与标准 `remoteAgent`；不复制 Agent 循环 | Developer UI 的 Agent 直连页没有小栖的认证头及 `xiaoqi_agent_turn` 元数据，会在模型前因缺 tenant 失败 | 正式消息/快照仍由 Genkit Agent 与既有 `CloudSessionStore` 所有；本地测试身份由 DevTools harness 所有 |
| 复现停止、继续与重新生成/分支 | Genkit 1.0.2 Agent 客户端 `sendStream(cancel:)`、`chat(snapshotId/sessionId:)`；服务端 task `/cancel` 路由与 SessionStore/snapshot | Flutter 负责取消与分支参数；`api.dart` 处理 `xiaoqi_agent_resume`、task 绑定与快照 | Flow 传递相同消息元数据、snapshot ID；新增仅本地 Flow 使用的定时 `/cancel`，复用同一 API；不复制 Agent loop | UI 运行面板没有停止按钮，用 `cancel_after_ms` 触发可控停止，再读取 `resume_input` | Genkit `SessionStore` 维护执行历史；业务 task/副作用记录仍由现有 SQLite store 维护 |
| 查看 Trace 中模型、工具和耗时 | 官方 CLI/Developer UI tracing；`Genkit.defineFlow` 为可从 UI 运行和追踪的官方入口 | Genkit span 已由 `genkit start` 收集；普通 API 路径已有 trace 证据 | 用 Flow 建立可发现、可重复的触发入口；不新增 Trace 存储 | 直接 Agent UI 失败时不会进入真实模型/工具步骤，不能用于诊断工具使用 | Genkit tracing / Developer UI |
| 保存可回归输入 | 官方 Dart Evaluation 支持 Flow 数据集；`https://genkit.dev/docs/dart/evaluation/` | Developer UI 已有 Datasets 页面；尚无小栖专用数据集 | 为 Dev Flow 建立小型输入集；先人工评估输出与 Trace，不添加未经验证的 LLM judge | 技能/插件安装状态属于账号数据；合成租户未安装能力时，数据集只能验证内置能力或固定 Fixture | Genkit 本地 Dataset / Evaluation；能力授权仍由小栖安装与授权数据所有 |

## 实施边界

- Flow 只在 `xiaoqi_harness/genkit_server/tool/genkit_devtools_agent.dart` DevTools harness 中注册，不进入生产 server 启动路径；不改 Flutter、公开 API 契约或线上状态。
- DevTools harness 使用仅对 loopback 监听的本地服务、短时合成 token、独立本地 SQLite 目录。token 不出现在 Flow 输入和 Trace。
- Flow 通过正式 `/v1/agent/chat` 路径调用服务端，所以租户上下文由原认证 `contextProvider` 解析，turn metadata 由 Flow 生成；不直接调用私有模型循环。
- `cancel_after_ms` 只为合成 Developer UI 租户提供本地调试入口，使用 Flow harness 内存中的短时 token 请求 loopback `/cancel`，不增加生产 HTTP 参数或状态所有者。
- 数据集里的每条记录只保存测试输入，不保存凭据。评估输出和 Trace 保存在本机 Developer UI。
- 合成用户没有真实账号安装的技能、插件或 MCP 连接。相关用例必须使用明确标记的本地 Fixture，或另行准备已授权的本地测试租户；不得将 Fixture 成功表述为真实账号已验证。

## 验收证据

### 取消入口修复（2026-11-17）

| 需求 | 1.0.2 官方源码 | 接入决定 | 缺口与状态归属 |
| --- | --- | --- | --- |
| 任务 API 停止正在运行的 attached Agent | `Action.run(cancel:)`、`CancellationController.link`；`agent.dart` SessionRunner 根据自己的 token 判定 aborted | 在 HTTP Action 入口适配取消令牌，转发原 Agent Action 的 typed input/stream/init/context，保留官方循环和快照 | 业务 `/cancel` 原先只取消内部模型 controller，未通知外层 SessionRunner。新增仅存活于请求期间的 controller 注册表，不保存执行历史；任务状态仍由 task、执行快照仍由官方 SessionStore 持有 |

这个适配不实现模型循环或快照。请求 context 只携带随机 invocation ID，控制器不进入序列化数据；请求结束清理注册表。若 SDK 将 attached turn 的取消控制器暴露给自定义 handler，可用其替换本适配。最初 15 项回归已通过，真实 provider 面板验证另行记录。

1. 本地 UI 能发现 `xiaoqi_agent_dev_test` Flow，并允许输入普通/工具请求。
2. Flow 执行通过原 `/v1/agent/chat`，Trace 中可看到小栖 Agent、模型调用和实际工具子步骤。
3. `cancel_after_ms` 触发现有任务取消路由；Trace/task/snapshot 最终状态一致；Flow 输出 `resume_input`，后续恢复/分支使用官方 snapshot ID。
4. 使用独立 DevTools 数据目录；未启动 Flutter App；未读取或写入生产数据库。
5. Developer UI 能创建 Flow Dataset 并运行至少普通对话与需联网的用例。人工核对结果，不用一次运行推断账号安装或生产有效性。

## 版本核对

- Server lockfile：`genkit` 1.0.2、`genkit_shelf` 1.0.2、`schemantic` 1.0.0。
- Flutter lockfile：`genkit` 1.0.2。
- `dart --version`：3.13.4 stable。
- 安装源码按 server `.dart_tool/package_config.json` 解析至 `D:/dev/pub-cache/hosted/pub.dev/genkit-1.0.2`；本方案不升级依赖。

## 2026-11-17 Traces 复核

- 初始调试进程因 `XIAOQI_CAPTURE_TRACES=1` 为每个临时 Agent Genkit 启动 reflection runtime；Flow 运行后最近 runtime 变成内部 Agent。Genkit CLI 的 `eval:flow` 通过 `getMostRecentRuntime()` 查动作，因此数据集评估报 `Cannot find action /flow/xiaoqi_agent_dev_test`。本地启动脚本改为 `XIAOQI_CAPTURE_TRACES=0`；Genkit CLI 提供的全局 dev instrumentation 仍采集内层 span，而内部临时实例不再注册 runtime。现在保留 API 与 Flow 两个 runtime，`eval:flow` 能找到 Flow。
- 数据集 `xiaoqi_agent_smoke` 已创建两条普通问答/联网输入；CLI 后续报 `No evaluators found in your app`，因为应用当前没有 evaluator（Developer UI 左栏也显示 0）。这与找不到 Flow 是不同问题，当前只把数据集用作可重复输入，不配置未确认的质量判分标准。
- Trace `3b530c2598d59453f71613b476eb69d0` / Flow Trace `09a0ce1a61a285a5b08660f3fc820158`：DeepSeek 两次意图识别调用均因连接 `api.deepseek.com` 超时失败。没有执行到普通 Agent 工具循环；这是网络失败，不能当作工具未注册或停止逻辑失败。隔离 SQLite 最终任务状态为 `waiting_for_user`，但 Trace 中发给 UI 的状态 Artifact 仍是 `running`，原因是 Artifact 在状态提交前由旧任务对象构造。
- 已修正等待用户状态的 Artifact 读取提交后的 task，并把没有 Agent 工具中断的业务澄清结束映射到 Genkit `stop`；Genkit 1.0.2 仍保留显式 `interrupted` 语义给真正的 ask-user/权限中断。`remote_agent_api_test.dart` 对应单测通过，检查了最终数据库状态、流式 Artifact 和 finishReason。
- 当前成功 Trace（上一轮）已经显示实际 `web_search` ×3 与 `web_fetch` ×1；这证明合成调试租户的联网工具链可运行。当前合成租户没有安装任何 skill/plugin/MCP capability，故不能据此证明真实账号能力安装状态或 App 端的选中状态传递。仓库现有 fixture Trace 可证明宿主技能加载、插件命令/资源工具路径，但尚未证明真实账号侧端到端调用。

## 2026-11-17 Developer UI 复测

- 普通问答/联网 Flow Trace：`1c4a2353f6ea08d1bb5e96d5767ac788`，`finish_reason=stop`、81.06 秒；Agent 子 Trace `7aabec447b43c0e43b9ff652ec411cc0`。执行树出现 DeepSeek 模型调用 ×4、`web_search` ×2、`web_fetch` ×3，未出现意图分类模型调用；普通文本已进入 Genkit Agent 的标准工具循环。
- 快照分支 Flow Trace：`9b7d45db115003089ab0340481beb085`，`finish_reason=stop`、65.41 秒；从上轮快照 `05469e83-b8f2-4b2b-8375-9a6cafbef475` 分支，成功生成新快照 `17a85547-d634-42c7-908e-f9fc6d0e14ff`。模型按本轮显式要求改用 Dart 文档。原始泛问答未指定 SDK 语言，模型选了 JavaScript 文档；这是问题约束/来源匹配问题，不是 Agent 路由或快照恢复失败。
- 第一条成功 Trace 已通过 Developer UI 的 “Add to dataset” 加入现有 `xiaoqi_agent_smoke`；未勾选“Include output as reference output”，避免将未经人工审核的模型输出设为金标准。该 UI 中没有 evaluator，故本轮不宣称评估分数；数据集用于保存可重跑输入。
- 现场截图中的 `Function call should not be used with prefix` 对应自定义 DeepSeek prefix 续写注入。该注入被移除，继续/恢复仅使用 Genkit 官方 snapshot/history；DevTools Flow 的 `continue_aborted_input` 也已去掉无效的 `prefix_content` / `prefix_reasoning` 字段。
- 状态恢复证据分层：`remote_agent_api_test.dart` 的取消→paused→同快照恢复→防止重复外部副作用测试通过；DevTools 中真实 provider 请求的快照分支通过。Flow 编辑器没有独立停止按钮，已为本地测试 Flow 增加 `cancel_after_ms`，由 harness 自动调用现有 loopback 取消 API 并输出 `resume_input`；尚需在 Developer UI 现场跑一次该用例后，才能把实时取消/恢复列为通过。
- 技能链路：`capability_runtime_test.dart` 的隐式技能发现用例通过，断言没有分类模型调用、Genkit Agent 实际调用 `use_skill` 并通过交付门禁。合成 DevTools 租户未安装真实账号技能/插件/MCP，因此账号侧 capability 安装与权限仍需通过真实安装数据另行确认。

## 取消修复后的 Ego 面板证据

- 停止：任务 `devtools-9f9257ea-2cc5-4b6d-8571-d95257a48328`，10 秒后调用现有 cancel API；Flow 24.25 秒返回 `aborted` / `paused`，快照 `368d6d0c-5cf4-4ce0-9b5c-8d13f8e94fc9`。只读数据库确认该官方快照 `status=aborted, finishReason=aborted`。
- 继续：同任务、同停止快照，Flow 42.67 秒返回 `stop` / `completed`，正文 7524 字；新快照 `078173ef-3977-4e69-a751-434292f7eb17` 的 parentId 指向上述停止快照。没有发送 provider prefix。前两次尝试因直连 DeepSeek 超时/TLS 中断失败；通过已经运行的 localhost:7890 代理恢复网络后成功。可选 `XIAOQI_DEVTOOLS_PROXY` 仅作用于本地 harness 的 DeepSeek 域名，不修改生产网络配置。
- 重新生成：从 `078173ef-3977-4e69-a751-434292f7eb17` 对同一问题“不要联网或调用工具。基于前文，用三句话概括狭义相对论。”重复运行两次 branch 输入。两次均 `stop` / `completed`；版本 A `497eaef0-ddc4-4909-881c-463fccb77783`、版本 B `05cff19b-fdce-4ea6-bd82-03f78b6c1383` 不同，parentId 都是同一基点；只读数据库确认 A 没有被 B 覆盖。这验证后台官方分支行为，不代表 Flutter 按钮真机验收。
- 修复后 `remote_agent_api_test.dart` 15 项通过，并加强停止用例：除了 task paused，还断言真实响应 aborted 以及官方 snapshot status/finishReason aborted；相关 Dart analyze 无问题。
