# 意图与能力范围修复实施记录

用户于 2026-10-20 授权实施已经交付的完整方案。基线 `fa10938`。

完整规格：`C:/Users/20833/.codex/visualizations/2026/10/20/01a15714-d24f-7c70-aa9b-00e38f8757a5/agent-intent-capability-plan-v1.md`。

本版本沿用既有聊天、停止、结果和 MCP 确认组件，不新增页面或视觉资产。用户选择表示偏好，自动激活仅绑定当前任务；新问答不得继承旧执行权限；用户纠正可撤销未执行要求。真实图片不可读时明确反馈，不生成替代品。

1. [x] 核对基线、官方参考和既有行为规格。
2. [x] 实现本轮契约、工具执行边界和能力范围分离。
3. [x] 实现产物引用、计划修订、取消/恢复与操作去重。
4. [x] 完成静态、自动化和真实模型验证；更新共享版本。
5. [ ] 部署服务器，验证健康和数据，记录客户端待用户验证项。

持久化数据保留，旧快照缺少显式选择来源时不推断执行权限。采用现有 CloudStore 的版本检查；不引入新 Agent 框架或外部权限服务。部署失败沿用脚本回滚。实现偏差和实际验收证据在本记录更新，不以本清单替代执行证据。

## 官方依据与实现对照（2026-10-20 核对）

用户要求工具按任务需要自动选择，不要求用户说出技能或工具名称。已删除“配置即开放全部执行工具”的旧测试断言，删除绕过语义路由的生图/附件关键词捷径。普通问答可以直接完成，也可以按信息需求使用读取/检索工具；不能将“普通问答”理解为所有工具一律禁用。

| 官方模式 | 官方文档 | 当前实现与验收 |
| --- | --- | --- |
| 模型分类、结构化结果、条件路由 | [Genkit Dart Agentic patterns](https://genkit.dev/docs/dart/agentic-patterns/#workflow-conditional-routing) | `intent_router.dart` 识别当前目标；`agent_runtime.dart` 使用 `ai.generate(outputSchema: TurnContract.proposalSchema, outputFormat: 'json')`。正常任务不再由关键词直接授权执行。 |
| 模型自动选工具，应用执行并反馈，循环直至回答 | [Genkit Dart Tool calling](https://genkit.dev/docs/dart/tool-calling/) | 使用既有 `defineAgent`/工具循环；按当前任务筛选相关能力，不强迫调用工具；技能和插件的隐含需求仍可自动激活。 |
| 工具说明清晰、结构化参数、控制候选工具数量、允许零次调用 | [OpenAI Function calling](https://developers.openai.com/api/docs/guides/function-calling) | 仅开放本轮相关执行工具；非执行问题不承接旧制卡/生图流程；结果读取和联网工具遵守既有产品设置。 |
| 路由分离不同任务，避免一种任务的提示污染另一种 | [Anthropic Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) | 技能目录元数据用于选择；旧技能正文仅从推理视图移除，保留原始历史和工具证据；自动激活不写回用户偏好。 |
| 观察工具轨迹和实际输出 | [Genkit Dart Evaluation](https://genkit.dev/docs/dart/evaluation/) | 使用 CLI flow 和真实模型验证，不以“模型说完成”代替调用证据。 |

上述是采用的官方模式，不是声称官方提供了 Xiaoqi 专用实现。`TurnContract` 字段、图片预算、同消息去重、租户隔离、取消/修订版本检查是本项目的业务与运行层约束；这些约束不要求用户显式点名工具。

## 实际证据与当前状态

- 共享 release：`2026-10-20-intent-scope-1`；client/server API contract：`17`。
- 真实模型语义与能力验证：`3b6b2c665db59c2f32c3aee2d3167c6c` 成功完成 6 个分类样例和 4 个能力链场景；`1f564b79f8dbaf495176202548321945` 是此前覆盖 5 个能力链场景及两次真实生图的完整 flow。真实图像检查轨迹 `300a5ccb3f80e2bf93c5f9b2d0837291`（MiMo）与 `a1317ea60602a229d5a75fcf7ac71421`（DeepSeek）均从服务端历史产物读取本地合成的红色 PNG，正确识别颜色且生图调用为 0。样本验证不等于所有表达或手机端效果均已验证。
- 旧验收误把“普通文字整理”要求为必须激活技能，已删除该要求。现分别验证普通文字整理可直接回答、相关技能任务自动选择和执行；不以强制激活来提高测试通过率。
- Genkit CLI 在 flow 成功后出现 Windows 缺少 `wmic.exe` 的子进程清理错误；成功依据是持久化的 flow 状态和实际工具轨迹，不能把 CLI 退出码称为正常。未安装额外系统组件。
- 服务端静态检查和最新 162 项自动化测试通过（删除一项旧关键词路由测试，并增加模型限制注册表验证）；客户端 3 项持久化/停止历史测试通过；共享版本 APK 于 2026-10-20 17:40 构建成功，SHA-256 为 `404835A4C4602DFB976C749C979C87029810D8F4A83214B44DC693821476B3EC`。客户端局部 analyze 有一条既有 `use_null_aware_elements` 信息提示，无编译错误。
- 接入模型上限取自一手官方资料并显式设置：DeepSeek Flash 上下文/输入 1,048,576 token、输出 393,216 token；MiMo V2.6 Flash 上下文/输入 1,048,576 token、输出 131,072 token。客户端旧的 128 输出上限已移除；未自行加入 tokenizer 或字符数截断。超长文本传输与上限参数已验证，未做百万 token 实际占用压测。
- 官方上限依据：[DeepSeek API 参数](https://api-docs.deepseek.com/api/create-chat-completion/)、[DeepSeek 模型限制](https://api-docs.deepseek.com/quick_start/pricing/)、[MiMo V2.6 Flash 模型卡](https://mimo.mi.com/models/en-US/mimo-v2.6-flash)、[MiMo Chat API](https://mimo.mi.com/docs/en-US/api/chat/openai-api)。
- 第一次部署在上传阶段遇 ECS API 网络超时，未到切换阶段。第二次部署已完成上传并启动远端 Docker 构建；本地轮询期间 ECS API 连续超时后退出，最后一次只读状态仍显示远端命令 `Running`，线上健康探测超时。因此当前发布结果未确认，不能声称服务已部署，也不能并发启动第二次发布；待 ECS 连接恢复后先确认该远端命令终态和线上 release/contract、健康、数据及唯一恢复点，再据结果完成或恢复部署。
- 未执行用户手机验证。无新增 UI 或视觉资产；现有技能菜单等独立改动保持原状。

后续核对：已彻底删除旧 API 中按关键词推断“图片未交付”的逻辑，完成状态以服务端本轮契约为准。文字讲解是否必需也改由结构化 `answer_required` 表达。路由使用 Genkit Dart 原生结构化输出，并按 provider 参数设置官方最大输出值（DeepSeek `max_tokens=393216`；MiMo `max_completion_tokens=131072`），替代此前临时 2048 上限，避免人为降低限制；模型和服务端仍受其官方上下文窗口约束。失败时保留不执行副作用的行为。
