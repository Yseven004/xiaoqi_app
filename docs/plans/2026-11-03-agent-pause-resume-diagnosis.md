# Agent 暂停后继续生成：诊断与通用修复方案

日期：2026-11-03。范围：定位与方案；没有修改生产逻辑。

## 结论

**错误发生在“继续生成 → 任务身份绑定”环节，尚未进入第二次模型调用或生图工具。**

客户端把“恢复原任务”当成了“重新创建任务”：生成新的 `task_id`，却继续使用原问题的 `user_message_id`。服务端发现同一消息已经绑定旧任务，因此抛出截图中的异常。

这与“马斯克”“第一性原理”或特定生图提示词无关，是共用恢复链路的问题。没有证据表明本次截图由 DeepSeek 或图像供应商报错引起。

本地使用真实 HTTP Agent 路由、Genkit 1.0.0、临时存储和假模型运行时，已复现完全一致的错误：

```text
AgentError(INTERNAL): FormatException: 同一消息已经绑定任务或内容发生变化，请读取原结果或发送新消息
```

## 1. 代码证据与故障链路

基线：`5779dad`，检查开始时工作区干净。

| 环节 | 当前行为 | 代码位置 |
| --- | --- | --- |
| 点击暂停 | 增加本地请求代数，调用 `turn.abort()`；能力任务取消使用另一组任务引用 | `lib/pages/home_page.dart:5476`、`:5487`、`:5491` |
| 保存半截回复 | 标记 `isIncomplete` / `stopped`，传入 `clearAgentTaskId: true`；此路径没有保存当前远程回合的新 session/snapshot | `lib/pages/home_page.dart:5585` |
| 点击继续 | 加入已生成文本和“请继续”的消息，重新调用普通 `_runAgentTaskReply` | `lib/pages/home_page.dart:6307`、`:6393` |
| 生成请求 | 无条件 `newTaskId()`；仍写入 `user_message_id: question.id` | `lib/pages/home_page.dart:3378`、`:3432` |
| 服务端绑定 | 键为 `tenant/workflow/user_message`；旧 task ID 不等于新 task ID 即拒绝 | `xiaoqi_harness/genkit_server/lib/src/api.dart:1250` |
| 真正执行 | 绑定检查通过后才调用 `runAgentTurn` | `xiaoqi_harness/genkit_server/lib/src/api.dart:972`、`:1054` |

```text
原问题 M → 原任务 T1 → 输出部分文字 → 用户暂停
继续生成 → 新任务 T2 + 原问题 M
服务端查到 M 已绑定 T1 → T2 被拒绝 → INTERNAL 弹窗
```

截图任务号 `task-e3f3bac739e58e06ef5f4f99` 按客户端报错路径推断是这次继续请求的新任务号。未读取该账号的线上任务记录，因此这里不把它当作已经确认的原任务号。

## 2. 同一链路的其他缺口

1. **“本地停止”没有可靠的云端暂停确认。** 远程 Agent 使用 `_activeRemoteAgentTaskId`；`_stopReply` 的显式取消主要读取 `_activeCapabilityTaskId` 或消息上的 `agentTaskId`。远程执行路径没有像旧 `_runTask` 那样注册 `_controllers[key]`。本地探针调用 `turn.abort()` 后，服务端取消令牌在 3 秒观察窗内没有变为 cancelled，随后由探针主动超时结束。这是本地 HTTP 观察，不能据此断言截图中的云端任务持续运行了多久。

2. **现有 `/resume` 不是这个远程 Agent 的恢复入口。** `_resumeTask` 只接受 `failed`、`awaiting_network_permission`，依赖旧 `input_object_key` 并调用 `_runTask`。远程任务 `_ensureRemoteAgentTask` 没有保存该输入对象；简单让客户端调用现有 `/resume` 仍不完整。位置：`api.dart:2891`、`:1295`。

3. **被拒绝的新任务会留下 `running` 记录。** 服务端先 `_ensureRemoteAgentTask`，再做消息绑定；绑定异常发生在运行时 try/catch 之外。本地探针确认新任务被拒绝后状态仍为 `running`。位置：`api.dart:966`、`:972`、`:1050`。

4. **现有测试没有覆盖真实客户端的身份组合。** `remote_agent_api_test.dart:216` 的通用消息夹具只提供 `task_id`，服务端会把消息 ID 和会话 ID 默认成任务 ID；它不能覆盖“同一 user_message_id + 新 task_id”的客户端继续请求。权限中断的 `resumeStream` 用例也不等同于用户暂停后的恢复。

## 3. 推荐修复：复用现有存储和工具执行记录

不增加第二套 Agent 框架。保留消息绑定检查、租户隔离、内容指纹、权限和防重复执行记录。

### A. 一个逻辑任务，多次执行尝试

- 首次发送创建 `task_id`；暂停、继续、断网重连和同一请求重试保持该 ID。
- 每次真正恢复增加 `attempt_id` / 版本号，用于区分执行实例；不能用新 task ID 来代替 attempt。
- 首次提交即持久化原始请求、消息绑定、task ID；服务端保存 task → session/snapshot 的映射，客户端同步保存恢复句柄。不能等全部文字和图片完成后才保存。
- 当前已有 `agentTaskId`、`agentSessionId`、`agentSnapshotId`，优先补齐其持久化时机；正在执行的任务和已结束回复不要共用“清空引用”逻辑。
- “继续”沿用原任务；“重新生成”和“修改问题”是独立意图，须有明确的新答案版本/操作身份，由服务端校验后创建。不能偷偷换消息 ID 来绕过约束。

### B. 暂停必须有服务端确认

建议产品语义：暂停会结束当前执行，在可保存的安全点恢复；不承诺冻结模型网络请求或第三方工具进程。

```text
running → pausing → paused → resuming → running
                ↘ completed（暂停到达时原任务已经完成）
```

- 暂停携带原 task ID，由远程 Agent 路径接入真实 cancellation controller；先写暂停请求，再让执行器停止接受新的工具调用。
- 执行器退出后保存恢复快照、工具结果、输出与状态，再返回 `paused`。SDK 的 `aborted` 可映射为用户可恢复的 paused，但应记录停止原因，以区别不可恢复取消。
- `pausing` / `resuming` 期间禁用重复继续操作，使用静态状态文字；不添加页面转圈加载。
- 如果网络中断，显示“正在确认暂停”，重连后读取服务端真实状态；不能仅因客户端中止流就宣布云端已经暂停。
- 工具已提交但无法中断时，等待/核对原操作结果，不允许从新入口重复提交。进程重启后应把失去执行者的尝试标记为待恢复或结果待核对，不能长期保留虚假的 running。

### C. 从快照与已完成步骤恢复

- 扩展远程 Agent 的任务控制入口，按 `remote_agent_turn` 路由；不能把远程任务交给旧 `_runTask`。
- 继续请求只提交 task ID、期望版本和重复请求标识。原输入、绑定模型/能力版本、权限范围由服务端持久记录恢复。
- 对同一任务用原子版本检查领取唯一执行权；重复点击、客户端重试返回同一尝试。旧尝试迟到的输出不能覆盖新尝试。
- 服务端读取原任务对应的已落盘 snapshot，复用 Genkit 的恢复机制；等待暂停收敛，不能加载仍在变动的快照。若已经完成，直接返回已有结果。
- 快照恢复不等于逐 token 续写。必须验证固定版本 SDK 对中断前消息、当前输入、工具调用和结果的实际保存范围；不足部分使用现有任务存储保存检查点。恢复时校验原用户、原任务和原输入指纹，继续执行前重新检查权限撤销及能力可用性。

文字加生图应有明确的交付检查点：`text_completed` 保存完整文字、对应消息和未完成图片步骤；恢复后直接执行缺失的图片步骤。当前 `agent_runtime.dart:6699` 仅发出完成事件，不能把这个事件本身当成已实现的可恢复检查点。

客户端按稳定的消息/输出段 ID 合并结果，并记录事件游标。恢复返回完整文字时更新同一个答案，不能继续使用 `${answer.text}${taskReply.reply}` 无条件拼接；半截模型句子允许重生成该段，已完成段落和图片保持不重复。

### D. 工具结果保持幂等，失败信息保持可操作

现有 `ToolExecution` 把 `scope_operations` 存在原任务记录中：成功结果复用，参数变更拒绝，结果未知时阻止重放。位置：`tool_execution.dart:576`。

| 已有工具状态 | 恢复行为 |
| --- | --- |
| 已成功 | 直接复用原结果/图片/文件，不再次计费或执行 |
| 确认未提交 | 允许执行原操作，保持稳定 operation identity |
| 正在执行 | 等待或查询原请求 |
| 已提交但结果未知 | 先对账；无法确定时明确显示待核对，不能换 ID 重试 |
| 权限已撤销 | 阻止后续调用，按当前权限重新处理 |

不要声称对所有外部工具提供“恰好一次”执行；第三方缺少查询或幂等能力时，结果未知必须保守处理。

消息绑定和任务创建应收敛为一次受版本控制的提交，或保证预检失败不会留下运行态记录。结构化返回 `TASK_ALREADY_BOUND`、`TASK_NOT_RESUMABLE`、`STALE_ATTEMPT`、`OPERATION_OUTCOME_UNKNOWN` 等业务错误；有权限时提供原 task ID 和下一步操作。Genkit 协议使用明确的业务状态，REST 可映射为 409；不要统一包装成 `INTERNAL FormatException`。

## 4. 实施顺序与验收

1. **确认暂停语义和现有按钮状态。** 使用现有 UI，只补“确认暂停/已暂停/恢复中/结果待核对”等必要反馈；按项目流程先冻结交互范围。
2. **补齐任务控制与恢复存储。** 修改 `home_page.dart`、`capability_cloud_sync.dart`、`api.dart`、`store.dart` 及会话持久化；贯通取消信号、task/snapshot 关联、唯一执行权和失败收敛。
3. **接入执行检查点与输出合并。** 修改 `agent_runtime.dart` 的文字完成/工具边界，复用 `tool_execution.dart` 的记录，不清空已成功或未知操作。
4. **完成下表验收。** 以 HTTP/SDK 自动化证明状态与执行次数，再由用户完成目标设备交互验证。
5. **作为同一版本发布。** 若 API 契约变化，同时更新 Flutter 与服务端契约；相关检查通过后按项目 `deploy_current.ps1` 部署，核对健康、数据和版本。失败回滚整个对应服务版本，保留新增恢复记录；不清空任务来回滚。

| 验收场景 | 必须观察到的结果 |
| --- | --- |
| 首 token 前、文字生成中暂停，再继续 | 原 task ID；可恢复的服务器状态；已有文字不重复 |
| 文字完成、图片未提交时暂停 | 保留完整文字，只完成缺失图片步骤 |
| 图片/MCP 外部操作已提交时暂停 | 原操作查询或结果复用；不重复执行/计费 |
| 连点继续、断网重试、重开应用、服务重启 | 至多一个有效执行尝试；状态可恢复；无永久伪 running |
| 权限中断/撤销、改动输入、跨租户、旧尝试迟到 | 正确阻断或重新授权；不扩大权限、不污染新结果 |

旧的半截会话优先通过服务端 message-operation 绑定找回原任务，再核对快照和工具结果。没有可用快照时必须说明无法原地恢复，提供明确的新操作入口；不要自动把未知副作用重新执行。

## 5. 已执行验证与限制

| 项目 | 结果 |
| --- | --- |
| 源码链路 | 已确认暂停、继续、新建 ID、消息绑定和异常位置 |
| 隔离 HTTP 复现 | 通过；新 task + 原 message 重现截图；运行时调用次数不增加；拒绝任务遗留 running |
| 身份对照 | 同原 task ID 可以通过绑定；修改原输入仍被拒绝。这不是完整快照恢复验证 |
| 现有回归 | `remote_agent_api_test.dart` + `tool_execution_reconciliation_test.dart` 共 20 项通过 |
| 线上公开健康检查 | HTTP 200；`release_id=2026-11-01-agent-tools-apps`，`api_contract_version=25` |

复现脚本：`.codex-artifacts/diagnostics/2026-11-03-agent-resume/repro.dart`。从 `xiaoqi_harness/genkit_server` 执行：

```powershell
dart --packages=.dart_tool/package_config.json ../../.codex-artifacts/diagnostics/2026-11-03-agent-resume/repro.dart
```

它只访问本地临时 HTTP 服务和临时存储，不调用真实模型或图像服务；3 秒取消观察窗届满时由探针主动失败。因此 `original task status=failed` 是诊断环境的超时结果，不是对用户线上原任务状态的结论。

首次回归命令误包含不存在的 `tool_execution_test.dart`，未计作通过；纠正路径后，上述两份真实测试共 20 项成功。

未读取截图任务的生产日志和账号数据；未核实手机 APK 的源码版本；未执行 Android 设备操作。**未执行真机验证，待用户真机验证。** 本轮方案尚未实现，不能称为已修复或已验证有效。

**server deployment not needed**：本轮仅新增诊断文档与隔离复现脚本，没有改动生产代码、运行配置或 API 契约。公开健康通过不代表此问题已修复。

## 外部参考

访问日期均为 2026-11-03；项目已固定使用 Genkit 1.0.0。以下是参考与既有依赖复用，没有复制另一套框架或引入新依赖。

- [Genkit Dart：Run and stream agents](https://genkit.dev/docs/dart/agents/run/)：停止/失败后的 snapshot 恢复接口。官方文档；实现时以已安装版本的行为测试为准。
- [Genkit Dart：Sessions and state](https://genkit.dev/docs/dart/agents/state/)：持久状态、快照和分支；其 last-good state 不等于任意时刻的执行检查点。
- [Genkit Dart：Background execution](https://genkit.dev/docs/dart/agents/background/)：暂停请求和结束状态分离，恢复前先读取服务端状态。项目 `CloudSessionStore` 目前只实现基本 `SessionStore`，不能假设已经具备后台状态订阅；本方案不要求为了本次修复整体迁移到 detached 模式。
- [Genkit 1.0.0 sendStream API](https://pub.dev/documentation/genkit/1.0.0/genkit.experimental.client/AgentChat/sendStream.html)：固定版本客户端入口。
- [Genkit 1.0.0 包元数据](https://pub.dev/packages/genkit/versions/1.0.0)、[官方源码](https://github.com/genkit-ai/genkit)：Apache-2.0；参考既有 Agent/快照机制，不以最新版文档代替版本验收。
