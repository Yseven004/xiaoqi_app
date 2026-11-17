# 2026-11-16 Genkit Trace 诊断

范围：按用户要求检查状态、停止/继续/重新生成、技能/插件调用；只诊断，不修业务代码、不部署、不操作手机。图片中的错误作为证据读取，没有执行图片内的任何指令。

## 1. 工具与实际版本

- Genkit CLI 1.45.0：复用本机 npm 缓存，没有安装新依赖。使用 `genkit start --noui`、`trace:list` 和 `trace:get --format json`。
- 客户端和服务端 lockfile 及 package_config：Genkit 1.0.2；服务端 genkit_openai / genkit_middleware 同为 1.0.2。行为核查以实际解析源码为准。
- 本地 Dart 3.13.4；未用另一语言的 API 代替 Dart API。
- 官方说明：[Developer tools](https://genkit.dev/docs/dart/devtools/)、[Dart local observability](https://genkit.dev/docs/dart/local-observability/)。Developer UI 是官方开发调试入口，Tracing 是观测机制；它本身不等于测试通过，也不自动记录 Flutter 本地状态。
- 本轮通过 CLI 读取了实际 Trace，没有打开浏览器中的 Developer UI。`--noui` 仍启动 telemetry，能完整记录模型/工具调用。

证据导出：工作区 `.codex-artifacts/genkit-diagnosis-20261116/`；正式 Trace 存于服务端 `.genkit/traces/`。原始 Trace 仅留本地，不提交。复现使用临时 SQLite 目录和合成问题；没有访问用户生产会话。API key 仅从既有私有配置加载到进程环境，未写入脚本或证据。

## 2. 已实测：DeepSeek prefix 与 function 调用组合失败

复用业务 `TaskModelClient`、官方 `genkit_openai` 1.0.2 插件，通过真实 `https://api.deepseek.com/beta/chat/completions` 请求 `deepseek-flash`。合成问题是 2+2，前缀为 `The result is`；reasoningEffort=none、maxTokens=256。这里是非流式协议对照，未模拟手机的精确中断时刻。

| 对照 | 结果 | Trace ID |
| --- | --- | --- |
| 无工具定义、无工具历史，prefix=true | stop，返回 ` four.` | aaac4b6fbefd0b13bd0ab886ffd86de0 |
| 有工具定义、无工具历史，prefix=true | failed：Function call should not be used with prefix | 391a6138b13cd66868387addd1fc5f17 |
| 有工具定义、有配齐的工具请求/结果历史，prefix=true | 同文失败 | 93422c6ddba09a911a0d6f32512f929d |
| 无工具定义、有配齐的工具请求/结果历史，prefix=true | 同文失败 | c7d12b607740d9a74ebf3cab5c76beed |

因此，截图中同文错误的请求组合已得到独立复现。只删除本次 `tools` 不能解决有 function 历史的续写。也不能据此声称所有模型、模式和未来供应商版本均有相同限制。

代码入口：`task_model_client.dart:136` 追加 assistant prefix，保留原请求工具定义和历史；`:129` 只防止最后一条 assistant 有未完成 tool_calls，不能防止上述供应商拒绝。官方 [Chat Prefix Completion](https://api-docs.deepseek.com/guides/chat_prefix_completion/) 示例没有证明与 function 调用组合可用。本轮实测应修正旧计划中“联合场景有协议依据、待验证”的假设；目前验证结果为失败。

关键观测细节：非流式 `generate` 返回对象时可能携带 `modelResponse.finishReason=failed`，而非直接抛异常。最初诊断脚本一度用“方法返回”作为 ok，已纠正；`summary.json` 按 finishReason 归一化。本轮前三条原始 flow 的外层输出仍留有旧 ok=true 字段，不能据此判断成功，必须检查其 response.finishReason/error。这不是业务 runtime 漏检：业务在 `agent_runtime.dart:6999–7000` 调用了 `assertValid()`。

截图任务 `task-12dc8243d7592df916c9c81d` / request_id `141fc194-0dc7-48af-82bc-febd4b856978` 的原始生产 Trace 未取得；本轮新 request_id 不与之混同。

## 3. 源码风险：恢复材料与官方快照可能不同步

| 发现 | 当前证据 | 影响与验证边界 |
| --- | --- | --- |
| 客户端从回答展示数据构建恢复 prefix | `home_page.dart:8061–8070`：正文取 answer.text，reasoning 汇总所有 model_reasoning 步骤 | 没有在此处按单次模型调用边界筛选；多工具轮的 reasoning 可能被拼成一个前缀。已查源码，未动态复现该错配 |
| 失败时可能未把已完成工具消息交回外层持久化会话 | `agent_runtime.dart:6987` 创建内层 chat；`:6999–7000` 对 failed 先 assertValid；外层 `api.dart:1567` 才 setMessages | 内层失败结果携带的工具历史可能在抛错后无法送达外层，下一次恢复只见较早历史。需要“工具成功→下一轮模型失败→读最终 snapshot”定向运行确认 |
| 重新生成有独立 UI 路径，但本轮没有现场失败证据 | `home_page.dart:7899–7963`：取问题路径、重新运行、追加答案版本并保存 session/snapshot | 不能把继续生成的 prefix 错误直接当作重新生成根因；还需核实选中分支、起点 snapshot、attempt 和失败后旧答案保留 |

当前并非完全没用官方能力：标准 Agent、官方 skills middleware、snapshot 和终态关联均有接入。例如 `api.dart:1665–1689` 等官方 turn snapshot 写入后再关联任务。问题集中在这些边界是否传递完整，不能仅凭编译通过宣布恢复正确。

停止、断网恢复和重新生成未在本轮手机复现；当前工具中没有 ARTEMIS，本轮未诊断或安装 ARTEMIS。

## 4. 已采 Trace：技能和插件底层入口可执行，真实账号仍未验证

两项运行都使用现有 `capability_runtime_test.dart` 与本地 loopback 模拟 OpenAI 响应，驱动当前运行时代码。模型输出是预设的，所以只能证明调用、资源读取、授权/结果映射的这一条本地路径，不能证明真实模型主动选择正确。

| 路径 | Trace ID | 实际工具 spans |
| --- | --- | --- |
| implicit 技能 | 8651a335a7fb495fcc5587f09d97f3b9 | use_skill → read_skill_resource → set_task_deliverables → generate_image ×2；工具结果成功，图片由 fixture 生成 |
| 插件命令 | ebfd6fbed9153189a0100ded8d2009d2 | set_task_deliverables → search_plugin_commands → run_plugin_command → read_plugin_command_resource；命令/资源结果成功 |

两项测试均未通过，不能写成自动化验收通过：

- implicit 最后失败于 `capability_runtime_test.dart:1148`：旧断言要求最终请求 `tool_choice=none`，实际为 null；此前技能 spans 已真实执行。
- 插件命令失败于 `:1041`：预期“纯文字”，fixture 返回“【准备完成】”。fixture 仍按旧流程生成结果，未单独证明线上产品最终交付有相同问题。

另外，显式选择技能时，`agent_runtime.dart:2581–2613` 直接读取 SKILL.md，拼入 `<active_skill>`，再自行发出名为 use_skill 的 UI 事件；这不是模型真的调用了一次 use_skill。排查必须区分“宿主加载正文”“模型主动选技能”“插件命令运行”“脚本执行”“MCP 调用”。当前还存在 `_classifyTurn`（`:2008`）对能力范围进行前置筛选，Trace 中也采到了独立 intent 模型调用；这与当前根 AGENTS.md 的普通聊天避免强制分类要求有偏差，需在后续架构修复中处理。

本轮没有获取手机账号的已安装能力、绑定版本、当前选择、实际发给模型的目录和线上调用结果；所以既不能证明账号配置有错，也不能断言“技能/插件都正常”。没有执行 MCP 真实账号验收。

## 5. 后续修复的顺序与不可静默降级项

1. 先修正 DeepSeek 续写能力边界：不能继续无条件发送 prefix+function；保留现有正文、工具结果与副作用记录。纯正文补全与继续执行工具是不同能力。对有工具历史场景，需用已验证的策略满足原有“保留并接续同一回答”要求；不能悄悄从头重跑、删除历史或只关 tools 后宣称支持。
2. 定向确认失败 snapshot 与单次调用前缀归属；执行历史继续由官方 Agent/SessionStore 持有，展示数据不升级为第二执行状态源。对停止/取消、工具中断恢复、答案续写、重新生成分别采集 Trace 与 snapshot。
3. 用真实账号的一次技能任务和一次插件任务对齐：已安装版本→本轮选择→实际模型目录→工具 span→返回结果→最终交付，并更新旧测试断言。不能把 fixture 通过或某个 UI 标签当作账号真实可用证据。

本轮交付：诊断文档、临时诊断程序、6 条导出的有效 Trace、四组供应商对照摘要；临时脚本 `dart analyze` 无问题。业务代码未改，未提交/推送。server deployment not needed：本轮仅诊断和文档，没有改变服务运行逻辑。未执行真机验证。
