# A2UI 回复不结束与联网搜索缓慢：根因和修复方案

日期：2026-10-13。范围：诊断、外部研究、方案、本次实现与远端部署记录。

**先修 A2UI 的错误等待、操作提交和恢复协议，再治理搜索循环。两段视频已分别印证“展示卡无限等待”和“交互卡提交缺少回合参数”；继续生成还暴露了 Python 工具错误直接终止回合的问题。新增视频的完整诊断与修复优先级见第 6 节。**

## 1. 已定位的根因

### 1.1 P0：展示卡片被误判成追问，回复进入无期限等待

视频不是单纯“模型还在输出”。03:00 的截图上方已经出现 **“请补充信息后继续”**，但卡片是纯展示的“2026 年菲尔兹奖得主”，没有输入框或提交按钮。

当前代码中，这个现象有完整的解释链：

| 位置 | 实际行为 | 后果 |
|---|---|---|
| `lib/pages/home_page.dart:2476` | 任意 `createSurface` 都设置 `clarificationPending = true` | 创建展示卡也被标记为需要追问 |
| `:2508` | 先 `await turn.response` | 后续等待发生在本轮服务端响应已经返回之后 |
| `:2512` | 有卡片且没有 interrupt 时进入追问分支 | 正常完成、没有中断的结果反而被拦住 |
| `:2518–2520` | 显示“请补充信息后继续”，等待 `clarificationAction.future` | 无交互的卡片永远不会完成这个 Future |
| `:2580–2595` | “已完成”、最终文本、session/snapshot 信息要等上面的等待结束 | 回复一直表现为生成中，正常结果提交被阻塞 |

**所以这里应修状态机，而不是增加模型速度或延长超时。** 在与当前代码一致的客户端中，视频里的文案还意味着 `turn.response` 已经完成，不能把这段等待算作模型推理耗时。

伴随问题也必须一起处理，否则只删一行会制造新缺陷：

1. `:2510` 已将 `_abortActiveAgentTurn` 置空，`:2520` 的本地等待没有取消出口；`:4110` 的停止逻辑没有完成该 Completer，存在悬挂任务与资源未释放风险。
2. `:2429` 的 Completer 在整个循环外只创建一次。第二次追问会复用第一次已完成的结果，不能支撑连续多轮表单。
3. `:2613–2614` 在正常结束时销毁 controller 并清空卡片。解除等待之后，还必须把展示卡片变成历史消息内容，否则卡片会消失。
4. 服务端 `agent_runtime.dart:1552` 和客户端 `home_page.dart:2570` 都以“文本为空”判失败；纯 A2UI 成功结果也可能被错误拒绝。

### 1.2 P1：搜索是嵌套模型调用，失败后没有搜索级收敛控制

实际调用路径：

```text
主模型判断需要搜索
  → web_search 工具
  → MiMo 模型执行内置搜索并生成摘要（非流式）
  → 摘要和来源交回主模型
  → 主模型生成最终文字／A2UI，或再次请求搜索
```

正常的一次搜索也至少包含“主模型前一轮 + 搜索模型 + 主模型后一轮”三个串联模型请求。串联本身不是错误；问题是简单问答没有独立的停止策略。

| 代码证据 | 结论 |
|---|---|
| `mimo_web_search_service.dart:86–113`：`chat/completions`、`stream:false`、900 输出 token、`max_keyword:3`、`limit:5`、35 秒 timeout | 搜索工具要等供应商生成完整响应；不是直接返回搜索命中的轻量接口 |
| `agent_runtime.dart:1109–1134`：失败变成普通 `ToolResult.response({status:unavailable})` | 主模型可以继续尝试；无分类的不可重试标记、重复查询去重、失败熔断或搜索次数上限 |
| `agent_runtime.dart:1514`：所有此路径请求统一 `maxTurns:12` | 只有通用模型轮次保险丝，缺少简单搜索的独立时间和调用预算 |
| 视频 01:35 的过程列表 | 已出现多条 `web_search` 进行中、遇到问题、已完成记录，说明问题不是仅凭感觉推断 |

**不能把 12 轮误当成最多 12 次搜索。** 本地锁定的 Genkit 1.0.0 在 `generate.dart:1413–1459` 按 `for` 循环逐个 `await` 工具调用；一轮模型可以发出多个工具请求。多个独立搜索若直接交给这个工具列表，也不能假定 SDK 已经并行执行。

35 秒是单次搜索等待阈值，不是整个任务的期限。举例：三个依次触及该阈值的调用，仅工具等待就会约 105 秒，再叠加主模型时间。这个数是机制说明，**不是本视频的实测耗时分解**。

搜索失败的具体原因尚不能下结论：代码会把连接故障、HTTP 错误、解析失败、缺少可验证来源等都传成搜索不可用。视频中的“遇到问题”不足以区分这些原因。无来源拒绝应保留，不能为了快而把模型记忆伪装成检索结果。

### 1.3 P1：取消与推理配置没有完整贯通

`webSearch.search(query)` 没有接收 Genkit 的取消 token，内部 HTTP 请求也未绑定它。`Future.timeout` 结束的是等待，不保证底层操作停止；Dart 官方说明原 Future 之后仍可能完成。[Dart Future.timeout](https://api.dart.dev/dart-async/Future/timeout.html)

此外，前端在 `home_page.dart:2407` 发送 `reasoning_level`，但当前 `genkit_server/lib` 没有消费这个字段，`defineAgent` 也没有设置对应 provider config。不能假定用户选择低推理后，新 Agent 链路确实降低了推理成本。

MiMo 官方搜索示例显式设置 `thinking: {type: disabled}`，当前搜索适配器未设置。应对受支持模型显式配置并测量，而不是猜测其默认值。[MiMo 官方 Web Search 文档](https://mimo.mi.com/docs/en-US/quick-start/usage-guide/text-generation/tool-calling/web-search)

## 2. 视频证据与结论边界

原视频长 **455.692 秒（约 7 分 36 秒）**；录屏开始时任务已经在运行，不能把视频长度当作完整请求耗时。

| 视频相对时间 | 可见证据 | 可得结论 |
|---|---|---|
| 01:35 | 重复的搜索开始、失败和成功状态 | 搜索阶段存在多次尝试；无法从截图还原每次 HTTP 请求细节 |
| 03:00 | 正文和结果卡已出现；卡片标题区显示“请补充信息后继续”；无提交控件 | 与前端错误的追问等待分支直接吻合 |
| 03:00–06:45 抽样 | 结果卡保持显示，仍有生成中表现 | 已显示结果后的长等待得到视频支持；没有对每一帧逐帧断言 |
| 07:30 | 显示“已停止”，出现“继续生成”，展示卡不再显示 | 视频没有证明任务正常结束；停止后的 UI 与正常完成不同 |

证据图片：[搜索阶段](evidence/2026-10-13-agent-latency/search-95s.jpg)、[卡片等待](evidence/2026-10-13-agent-latency/card-wait-180s.jpg)、[停止后](evidence/2026-10-13-agent-latency/stopped-450s.jpg)、[45 秒间隔总览](evidence/2026-10-13-agent-latency/contact-sheet.jpg)。视频里的回答内容仅作为界面证据，本报告不替它的事实准确性背书。

源码基线：本地 Git HEAD `7f72bb0982b066ad7d29c39e3d1ff7f53c53d565`，调查前工作区干净。依赖锁定 `genkit 1.0.0`、`genkit_a2ui 0.4.0`、`genkit_openai 1.0.0`。尚未核对录屏 APK 与服务器镜像的构建 SHA，也没有取得对应线上 trace，因此不把所有等待秒数都归因于已发现的某一项。

## 3. 官方文档与优秀开源 Agent 的可借鉴点

### 3.1 Genkit Dart：展示、完成和用户中断是三件事

官方 A2UI 文档把 `createSurface` 定义为 UI 数据通道的一部分；用户操作作为后续消息发送。流式文档要求消费 chunks 并取得最终 response。需要用户补充或审批时使用显式 interrupt，而不是把“有 UI”解释成“必须暂停”。[A2UI](https://genkit.dev/docs/dart/agents/a2ui/)、[Run and stream](https://genkit.dev/docs/dart/agents/run/)、[Interrupts](https://genkit.dev/docs/dart/agents/interrupts/)

对本项目的含义：保留 `defineAgent`、`remoteAgent`、session/snapshot 和 `a2ui()`；修复应用层语义，不需要重新手写整个 Agent 循环。也不能在第一张卡片出现时就强行宣告任务成功，后面仍可能有组件更新、工具动作或真实失败。

官方文档和本地技能参考存在随版本演进的示例差异，实施必须以当前 lockfile 的 API 为准；本次已额外核对安装包的工具循环实现，不将其他语言 SDK 的行为直接套到 Dart 上。

### 3.2 可复核的 GitHub 参考

以下项目均只参考架构，不直接复制代码或新增其框架依赖。版本于 2026-10-13 读取并固定到 commit；不把搜索引擎抓取时间当作最后更新时间。

| 项目／版本／许可证 | 已核对实践 | 在小七中的应用 |
|---|---|---|
| [Vercel Chatbot](https://github.com/vercel/chatbot/tree/c2f8235e1f3ea903ad8b7f61447c4f74164b5c58)，`c2f8235e`，Apache-2.0 | [请求入口](https://github.com/vercel/chatbot/blob/c2f8235e1f3ea903ad8b7f61447c4f74164b5c58/app/%28chat%29/api/chat/route.ts) 明确设置 `stopWhen: isStepCount(5)`，按模型配置推理参数 | 循环约束和推理配置落到代码；不要只用提示词要求“快一点”。不照搬其 5 轮数值 |
| [LangChain Local Deep Researcher](https://github.com/langchain-ai/local-deep-researcher/tree/03537326ffa0dd90c9702bece2f3aeba5d84162a)，`03537326`，MIT | [graph.py](https://github.com/langchain-ai/local-deep-researcher/blob/03537326ffa0dd90c9702bece2f3aeba5d84162a/src/ollama_deep_researcher/graph.py) 在 `route_research` 用计数决定继续检索或进入最终摘要 | 把“继续搜”和“用已有证据回答”分成可控分支；普通问答不能默认承担深度研究循环。其边界计数需按源码理解，不照抄阈值 |

Anthropic 的工程建议强调按任务复杂度选择简单工作流、路由或 Agent，额外自主循环会增加延迟与成本。OpenAI 的延迟指南建议减少串行请求、限制不必要输出，并行处理真正独立的步骤。[Anthropic Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)、[OpenAI Latency optimization](https://developers.openai.com/api/docs/guides/latency-optimization)

**取舍：本项目先修有限预算、正确结束和取消，不新增 Planner／Reviewer／多 Agent。** 对这个简单事实查询再加一层规划模型，会增加串联请求，缺少必要性。

## 4. 具体实现方案

### 阶段 A：修完成语义与卡片生命周期（最高优先级）

目标用户仍为现有聊天用户，入口和主要操作保持现有流程；成功标准是“展示结果能正常结束，真正追问能等待并恢复”。下面是待实施的交互契约，不代表已经实现或经过用户验收。

| 状态 | 进入条件 | 用户看到什么 | 如何退出 |
|---|---|---|---|
| generating | 本轮仍在生成或执行工具 | 正文／A2UI 增量内容与准确步骤说明 | 最终 response、中断、失败或取消 |
| completed | 正常最终 response 已提交，必要交付物有效 | 保留正文和展示卡，生成状态结束 | 新消息或可选卡片操作开启新回合 |
| awaiting_input | 服务端明确提出带 request ID 的用户输入请求 | 可操作表单和“等待你补充” | 有效提交、取消、会话切换；不占用生成中状态 |
| failed / cancelled / partial | 真实错误、用户取消、部分交付 | 保留有效内容并说明实际状态 | 重试失败步骤或开启新回合 |

具体改动：

1. 删除 `createSurface → clarificationPending` 的自动推断。展示卡默认不阻塞完成；有按钮也不必然代表必须回答。需要输入时用服务端显式 interrupt／经过验证的输入请求契约。网络授权仍按独立类型处理，不能削弱现有权限边界。
2. 把 surface controller 和有效 A2UI envelopes 的所有权移到消息模型／消息视图生命周期。最终 response 到来时保存正文、surface 数据、sessionId、snapshotId、终态；会话重开可重放。不能只删等待后继续执行原有 `dispose()`，否则结果卡消失。
3. 每个输入请求有独立 requestId、schema 和提交状态；提交一次后去重，连续两次追问创建两个独立请求。取消、切会话、组件销毁都能终止本地等待。等待输入期间不保留一个无法取消的生成 Future。
4. 完成校验从“必须有文本”改成“有有效文本或可渲染的 A2UI／所需交付物，且 finishReason 为允许的终态”。空白 surface、错误组件或不完整结果不能冒充成功；aborted、failed、interrupted 分开处理。

建议的状态约束：`surface_created` 只更新展示数据；`response_finished` 才提交本轮完成；`input_required` 才进入等待输入。最后一个 UI 块到达与 Agent 结束不是同一个事件。

主要文件：`lib/pages/home_page.dart`、现有对话消息持久化模型、`xiaoqi_harness/genkit_server/lib/src/api.dart`、`agent_runtime.dart`。A2UI 数据字段采用可选新增字段，旧纯文本会话仍可读取；先确定数据序列化和恢复范围，再落地迁移。

### 阶段 B：为简单联网问答建立有限搜索预算

以下数值是首轮灰度实验参数，不是已经达到的性能，也不是适合所有任务的固定上限：

| 项目 | 简单事实问答建议初值 | 边界 |
|---|---|---|
| 搜索调用 | 正常 1 次，必要时最多补充 1 次 | 第二次必须针对缺失证据／不同查询；同一失败查询不循环 |
| 单次／累计搜索等待 | 单次 15 秒，累计 25 秒 | 以统一 deadline 的剩余时间裁剪；包含重试等待 |
| 整轮期限 | 60 秒 | 到期诚实返回部分结果／检索失败；复杂技能和长任务另有预算 |
| 搜索摘要和结果数 | 摘要上限先试 300–500 token，3–5 个来源 | 以事实覆盖率与来源完整性回归结果决定，不截掉关键证据 |
| 推理配置 | 简单检索工具关闭不必要的深度思考；主模型遵循用户选择 | 按供应商支持的字段映射，不静默更换用户选定模型 |

执行策略：

1. 保留现有 Agent，由 per-turn 的 `SearchBudget` 管理调用次数、累计耗时、失败类别和规范化查询。预算属于当前任务／回合，恢复时不能被重新初始化后绕过；只有显式新任务才重置。
2. 对重复查询做本轮去重和进行中请求合并。达到预算后，从本轮后续模型请求移除搜索工具，保留已有来源并进入“回答／说明无法核验”阶段。不能只返回 `budget_exceeded` 字符串后仍允许模型不停调用。
3. 分类处理失败：鉴权、配额配置、无有效来源等不原样重试；429／暂时连接故障只在剩余预算允许时有限重试，尊重 Retry-After。不要为躲过时间限制偷偷切到其他付费服务。
4. 将 `CancellationToken` 接到支持取消的 HTTP 请求或该调用独享的 transport。取消后停止重试、禁止迟到结果写入当前任务，准确区分 cancelled 与 unavailable。共享 Client 不能因一项任务取消而关闭其他用户请求。
5. 为 `reasoning_level` 建立已支持模型的参数映射，记录最终生效配置。MiMo 检索调用显式采用官方支持的 thinking 设置；先做相同查询的 A/B 测量，再决定是否将非流式改成流式。

`maxTurns` 继续保留为最终保险丝，但不承担搜索次数限制。触及限制应正确处理 aborted 并保留已完成内容。若需要第二个独立来源，可在一个有预算的检索工具内部做小规模有界并行；不要假设 Genkit Dart 1.0.0 会并行执行同一轮所有工具，也不要并行有依赖或副作用的动作。

进一步替换为直接检索 API，确实可能省去搜索模型的摘要阶段；这属于后续选型，需要比较中文召回、来源质量、成本和服务可用性。当前先优化已有 MiMo 链路，不把更换供应商作为 P0 的前提。

### 阶段 C：补足耗时观测，验证每一段都真正结束

统一关联 `task_id + turn_id + tool_call_id + request_id`，记录以下五组时间点和计数：

| 观测组 | 必须记录 | 解决的问题 |
|---|---|---|
| 首次输出 | 请求受理、首个文本、首个可渲染 surface | 区分启动慢和生成慢 |
| 每轮模型 | provider、model、实际推理配置、开始／结束、finishReason、token 用量（供应商有返回时） | 判断多轮模型耗时和配置是否生效 |
| 每次搜索 | 开始／结束、错误类别、HTTP 状态、来源数量、缓存命中、剩余预算 | 不再只显示“遇到问题” |
| 完成提交 | 最后有效内容、后端终态／快照提交、客户端收到 response、客户端退出生成态 | 直接定位已生成但不结束 |
| 取消与恢复 | 取消发起、transport 取消、任务终态、迟到事件丢弃、恢复次数 | 验证停止确实生效且不重放工具 |

关键指标是 `客户端退出生成态 − 客户端收到最终 response`。本次 A2UI 缺陷主要落在这项，不是 TTFT。该项先设 p95 < 500ms 的验收目标；服务端实际首字和总耗时基线需采样后确定，不能先承诺“全部 3 秒完成”。

本地开发按 Genkit 技能要求通过 `genkit start --non-interactive -- ...` 收集 trace；生产使用受控结构化日志／遥测，不能仅打开 dev 模式。日志默认不写密钥、完整用户材料或完整检索正文。进度事件使用 call ID 更新同一工具行，避免把多条状态误看成更多调用。

## 5. 实施顺序、验收与回滚

### 推荐顺序

1. **A2UI 完成与持久化修复**：先冻结上述状态语义，再实现；估计 1–2 个工程日，取决于现有消息模型能否直接保存 A2UI 数据。
2. **搜索预算、错误分类、取消贯通**：估计 1–2 个工程日；先保留供应商，减少变量。
3. **trace 对照和目标平台回归**：估计 0.5–1 个工程日，加上等待真实请求样本的时间。没有供应商延迟样本前，不承诺总耗时下降百分比。

这是工程量估算，不是本次已完成的开发工作。此次不新增深度研究模式，不做多 Agent 架构迁移，不改变联网授权规则，不把展示卡改成截图。

### 必须通过的验收

| 场景 | 判定标准 |
|---|---|
| 文本＋无按钮 A2UI 结果卡 | 最终 response 后结束生成；卡片留在历史消息，重开仍可见 |
| 纯 A2UI 结果 | 有效 UI 可以成功；空／无效 UI 正确失败 |
| 一次与连续两次追问 | 只有显式输入请求进入等待；每次响应关联自己的 requestId；取消和切会话无悬挂等待 |
| 搜索成功、失败、重复查询、两条同轮调用 | 搜索预算可证明未突破；无来源不冒充已核验；最终可以正常收敛 |
| 搜索中取消、超时、断流、恢复 | 本地与服务端终态一致，不重放已完成工具，不接受迟到结果覆盖新回合 |

实现后分别记录静态／自动化检查、同状态截图、真机与部署验证；正确性必须覆盖现有网络授权、混合生图任务和旧会话兼容。组件与服务测试已运行；本次仍未执行真机录屏交互，待客户端包更新后验证真实设备案例。

发布按项目既有流程：确认目标服务，保留镜像／版本回滚点和数据备份，经 Cloud Assistant 更新对应服务，检查健康与数据完整性。客户端修复必须随新版 App 发布，仅重启后端不能解决本次前端无限等待。预算灰度使用服务端开关；新增消息字段保持向后兼容，回滚程序不能删除已保存的 surface 数据。

### 当前完成状态

| 项目 | 状态 |
|---|---|
| 视频抽帧与源码根因定位 | 已完成；A2UI 等待根因有相互印证 |
| Genkit Dart 官方资料、锁定 SDK 源码、行业项目研究 | 已完成；参考版本与链接见上文 |
| 线上每次搜索失败的精确归因 | 未完成：缺对应 trace、HTTP 错误细分和部署版本核对 |
| 代码修改／自动化检查／上线 | 本地代码已修改并通过服务端测试与静态检查；远端服务已完成构建、切换与健康核对 |
| 真机验证与性能收益确认 | 未执行验证，待修复后目标平台验证 |

**建议首先实施阶段 A；它能直接消除已经证实的无期限等待。阶段 B 用有限搜索预算处理剩余的真实耗时，不用前端假完成掩盖后端仍在运行。**

## 6. 新增视频：点击卡片报错，继续生成又失败

补充时间：2026-10-13。视频 `f4e0b73e97097df25de0070732f0c6b7.mp4`，时长 66.432 秒。本节记录诊断与方案补充。

**这是两个不同的异常，加上一个恢复流程缺陷，不是同一个错误重试两次，也不是简单的 A2UI 渲染失败。**

### 6.1 第一次失败：卡片 action 缺少小七自定义的回合 metadata

[00:42 错误截图](evidence/2026-10-13-agent-latency/action-error-42s.jpg) 清晰显示：

```text
AgentError(INTERNAL): FormatException: Genkit Agent 回合参数缺失
任务编号：task-286902b32d53ccecbdda395f2
```

当前源码可以完整定位这一错误，不需要假设模型服务中断：

| 链路 | 源码位置 | 实际行为 |
|---|---|---|
| 首次普通消息 | `home_page.dart:2404–2419` | 构造 `turnMetadata`，在 `Message.metadata.xiaoqi_agent_turn` 中携带 task ID、模型、联网模式等 |
| 卡片交互 | `home_page.dart:2431–2440` | 从 `onSubmit` 取 action，完成本地 Completer |
| 提交卡片结果 | `home_page.dart:2531` | 直接 `chat.sendStream(message: actionToMessage(action))`，没有附加回合 metadata |
| SDK helper | 已安装 `genkit_a2ui-0.4.0/lib/client.dart:47–62` | 返回包含用户操作摘要和 A2UI data part 的用户消息；不生成小七私有的 metadata |
| 服务端校验 | `api.dart:517–527` | 读取最新用户消息的 metadata；不存在 Map 时抛出视频里的同一句异常 |

`chat` 保持 session 连续性，不等于自动把上一条用户消息的自定义 metadata 复制给下一条。最新用户消息此时就是卡片 action；后端没有回退读取已有任务配置。

**归因：小七的消息适配契约不一致。** Genkit helper 不知道本项目的 `xiaoqi_agent_turn` 是合理的；遗漏发生在应用层。第一条普通消息走了封装，卡片消息绕过了封装。

修复要求：统一普通消息、A2UI action、重试消息的构造入口。短期必须给 action Message 附加经过整理的本轮配置，并保留 helper 生成的 content；不能只把 action.context 拼成一句文字而丢弃结构化选项。长期把已验证的执行配置绑定到服务端 session／task，让后续 action 通过受校验的引用继承，避免每个入口都靠人工复制 metadata。

配置继承必须保留账号授权检查：验证 tenant、session、task、surface、request 的所属关系；不能接受模型控制的 action.context 修改联网模式、技能权限或账号。明确沿用逻辑任务 ID 还是创建子回合 ID，不能在正常 action 中误重用已终结任务的执行状态。

### 6.2 第二次失败：继续生成触发 Python 脚本错误，并被升级为整个任务失败

[01:04 错误截图](evidence/2026-10-13-agent-latency/continue-error-64s.jpg) 显示：

```text
AgentError(INTERNAL): tool "execute_python" failed: Bad state: stderr:
File "/workspace/main.py", line 16
ValueError: not enough values to unpack (expected 3, got 2)
error: 脚本退出码: 1
任务编号：task-e2222b86c4779d18c53ca299
```

这说明第二次已进入工具执行：某处按三个变量解包，拿到的元素只有两个值。截图中邻近代码含 `Row`、`children`、`b1_` 等字样，**提示可能在用 Python 构造 UI 数据，但未取得完整脚本，不能把具体生成用途当成已证实事实**。仓库当前应用源码没有找到对应 `opts1`／该动态脚本片段，不能靠修改仓库里一个假想的 `main.py` 解决。

能够确认的异常传播路径：

| 位置 | 行为 | 影响 |
|---|---|---|
| `code_execution_service.dart:165–174` | 收集 stdout／stderr；`ok != true` 时抛 `StateError` | 普通脚本执行失败进入异常通道 |
| `agent_runtime.dart:1038–1046` | 记录 `tool_failed`，随后直接 `rethrow` | 没有把可修复的脚本错误返回给模型进行有限纠正或降级 |
| `api.dart:665–671` | runtime 抛错就把任务标为 failed，并继续抛出 | 整个回合停止 |
| `home_page.dart:2597–2604、4064–4094` | 包装成任务失败弹窗 | 用户无法从原卡片继续，看到的是内部堆栈 |

修复要求：区分“模型生成脚本错误”“基础设施故障”“取消”“权限拒绝”。可修复、无副作用或已确认可安全重试的脚本错误返回有类型的工具结果，例如 `code=script_error`、`retryable=true`、经过脱敏和限长的 stderr；允许最多一次有明确修改的纠正，然后停止工具重试并给出可理解的结果。取消与权限错误不进入修复循环，副作用不确定的执行不能盲目重跑。

若只是生成 A2UI 组件树，优先通过 A2UI middleware 直接输出结构化 UI；没有程序化计算需要时，不应额外调用 Python。当前 `agentToolNamesForRequest():619` 在代码执行可用时就暴露工具，工具描述虽然要求仅在必要时调用，但缺少按本轮任务需求限制的执行约束。先核对完整 trace 再确定这次工具调用是否属于多余调用。

### 6.3 “继续生成”实际是文本续写，不是恢复这次交互

两张弹窗的任务 ID 不同。当前源码也确认该路径会新建任务：

1. `_continueStoppedReply()` 在 `home_page.dart:4979` 只取到原始问题为止的历史。
2. `:5032–5034` 加入已生成的 assistant 文本和“请从这段已生成内容之后继续，不要重复已有内容。”；没有加入用户选中的 A2UI action。
3. 再调用 `_runAgentTaskReply()`，后者在 `:2373` 创建新的 task ID。它从 question／较早历史选择 snapshot，没有明确使用这次失败交互的最新检查点。
4. 原 action 在 `:2522–2529` 只写到临时 `answerSummary`。出错后 `:2613–2614` 销毁 controller 并清空卡片；`_savePartialAgentReply():3439–3451` 保存文本，未传入该 action 与最新 snapshot。

因此，该流程没有保证保留“用户已经选了哪个选项、哪个输入请求已提交、上一阶段已经完成什么”。这能解释为什么继续生成可以进入新的工具路径；但没有线上 trace，不能断言遗漏 action 是模型调用 Python 的唯一原因。

### 6.4 必须合并到阶段 A 的修复范围

| 优先级 | 改动 | 验收要求 |
|---|---|---|
| P0 | 统一 Message 构造与回合配置继承 | 首次消息、卡片 action、第二次 action 都不再出现“回合参数缺失” |
| P0 | 收到第一轮最终 response 后立即保存有效检查点与卡片，不等交互完成才保存 | action 提交失败不丢失正文、卡片、sessionId、snapshotId |
| P0 | 保存 action 为 pending／acknowledged／failed，并绑定 requestId 和幂等键 | 双击只处理一次；网络失败可重试同一 action；恢复不重复已确认操作 |
| P1 | 将“重试提交”“恢复工具步骤”“继续文本回答”分成不同恢复策略 | 按实际失败位置恢复，不统一重建一句“继续生成”的普通对话 |
| P1 | 工具错误分类与有限纠正，修正状态文案 | 脚本错误不直接抹掉已完成回答；failed 不显示 completed，取消才显示已停止 |

卡片自身还要区分“选择／修改字段”和“提交”。当前 listener 对任何解析成功的 action 都结束等待，不能只凭按钮外观判断意图。需要核对发出的 action.name 和 context：局部选择更新表单状态，明确 submit 才提交；若采用点击选项即提交，就不应再显示误导性的多选和提交按钮。视频不足以证明实际是点击哪一个控件触发，需要通过组件事件验收确认。

新增回归场景：提交前修改选项、正式提交、连续两次追问、提交时断网／双击、提交失败后重试、脚本纠正失败后正常结束。验证结构化选择和原图引用保留，恢复期间不默认扩大工具权限。具体脚本工具验收用受控的解包错误案例，不能依赖模型恰好再次生成同一段坏代码。

### 6.5 本次证据边界

已完成视频截图和本地源码核对；两次弹窗的直接错误均已读出。未取得服务端 task trace、动态 Python 全文、实际 action payload 或 APK／部署版本对应关系；诊断阶段未运行真机交互。两条任务 ID 可用于后续只读日志查询。原 [03:00 展示卡等待问题](evidence/2026-10-13-agent-latency/card-wait-180s.jpg) 与本节是同一交互生命周期的不同缺陷，不能只修其中一个就宣称 A2UI 完整可用。

## 7. 本次实现与验证记录

已落地以下最小闭环修复：

1. 客户端只把包含可交互组件的 A2UI 更新标记为待输入；纯展示 surface 在最终 response 后结束生成并继续渲染。纯 UI 结果使用短文本占位保存 assistant 行，避免被“空文本”校验误判为失败；用户停止任务时，本地等待也会被取消。
2. A2UI action 保留 `actionToMessage` 的结构化内容，并附带本轮 `xiaoqi_agent_turn`；服务端在 action 消息缺少该 metadata 时，从同一 session 的前一条用户回合继承已校验配置，同时保留原始 `current_turn_text`。
3. `execute_python` 对普通脚本错误返回脱敏的 `script_error`，最多允许一次明确纠正；取消会继续向上抛出。`web_search` 对同一查询做回合内缓存，每回合最多实际执行两次不同搜索，重复查询不消耗预算。
4. MiMo 搜索请求按官方工具协议收紧为单关键词、最多三条结果、500 completion tokens、关闭 thinking，并将单次超时从 35 秒降到 15 秒。

验证结果：`dart test test/mimo_web_search_service_test.dart test/remote_agent_api_test.dart test/agent_runtime_test.dart` 通过（23 tests）；Genkit 服务端 `dart analyze` 通过。Flutter `home_page.dart` 分析无错误，仅保留既有 `_runLegacyAgentTaskReply` 未使用警告。全量本地 `dart test` 另有 3 个既有 Docker 沙箱夹具失败（runner 未返回任务结果／撤销代理失败），单独重跑仍复现，未归因于本次改动。

远端部署记录：通过 Alibaba Cloud ECS Cloud Assistant 更新香港实例 `i-j6cdji1nji415swaliji` 的 `xiaoqi-single-server-app-1`。构建上下文同时同步了 3 个运行时源文件和 2 个回归测试文件；远端 Dockerfile 的 `dart analyze`、完整 `dart test` 与 CLI 构建均通过。新镜像 ID 为 `sha256:8520077ff92fd2b7913e6b2cec1cd4d1cc79da5bf284e2a5cd9b3026a8b3627b`，旧镜像保留在 `xiaoqi-genkit-server:rollback-20261013-014447`。服务切换后容器为 `running|healthy`，公网 `/health` 返回 `{"status":"ok"}`；部署前后业务数据清单一致（SQLite 的临时 `-wal`／`-shm` 文件排除在比较之外）。回滚源代码与数据备份位于 `/opt/xiaoqi-single-server/backups/agent-latency-20261013-014447/`，其中本次数据快照为 `xiaoqi-data-retry3-before.tgz`。客户端 Flutter 修复尚未随服务端自动发布，需重新构建并安装新版 App 后再做真机录屏回归与真实供应商延迟对比。
