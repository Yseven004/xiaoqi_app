# Agent 混合文本与生图失败：精准根因与通用修复方案 v2

日期：2026-10-12

## 结论

这次“讲解马斯克第一性原理，并生成图片”的失败已经由生产日志精确定位，不是文字模型没有遵循“先文字、后图片”，也不是图片工具未被调用。

图片服务确实在文字完成后被调用，但当前实现把包含“马斯克”的整句原始请求直接拼成 Seedream 提示词。火山方舟随后以 HTTP 400 拒绝请求：

```text
The request failed because the input text may be related to copyright restrictions
Request id: 021791779517302cd9ac3abd2c47e334a510ad7678f857e843483
```

同一时间段的“光合作用”对照任务走相同执行路径并成功生成 1 个图片产物。因此，本次图片失败的直接根因是：

1. 应用没有把“知识来源/人物背景”和“图片实际需要表达的视觉内容”分开。
2. Seedream 对传入的公众人物姓名触发了输入版权/人物策略过滤。
3. Remote Agent 在图片失败、产物为零时仍把任务写成 `completed`，客户端因此清除占位并显示“已完成”。

技能自动路由还有两个真实缺陷：普通混合任务会无条件开放全部技能，且 `read_skill_resource` 的 schema 与服务端校验不一致。它们解释了截图中的 `use_skill` 重试和 `read_skill_resource` 失败，但没有导致这一次 Seedream 400；该次任务在技能失败后仍完成了文字并调用了图片服务。

## 生产证据

### 失败任务

- 任务 ID：`task-d86c6fb522617c80c8417392`
- 用户输入：`给我讲解马斯克第一性原理，顺便生成一张图片给我加以理解`
- 文字模型：`deepseek-flash`
- 图片模型：`doubao-seedream-5-0-lite-260128`
- 最终任务记录：`completed`
- 图片产物：`0`

事件时间线（UTC；北京时间加 8 小时）：

| 时间 | 事件 | 结果 |
|---|---|---|
| 04:31:28 | 图片意图分类 | `requested=true`, `answer_before_image=true` |
| 04:31:32 | `use_skill` | 首次因显示名/ID 不匹配失败，使用精确 ID 重试后成功 |
| 04:31:34 | `read_skill_resource` | `当前技能版本没有该资源` |
| 04:31:57 | `text_completed` | 文字解释正常完成 |
| 04:31:57 | `generate_image` | 服务端补充生图开始 |
| 04:31:58 | `generate_image` | HTTP 400，输入文本涉及版权限制 |
| 任务结束 | 状态计算 | 错误地标为 `completed`，产物为 0 |

视频与生产快照一致：图片占位出现后消失，文字保留，但用户没有看到真实失败原因。

### 成功对照任务

- 任务 ID：`task-7e1c649a75d7ba47456d07f0`
- 用户输入：`给我讲解光合作用原理，顺便生成一张图片给我加以理解`
- 相同文字模型、相同图片模型、相同“先文字后图片”路径
- `generate_image` 成功
- 图片产物：`1`
- 客户端随后成功请求图片文件

这组 A/B 证据排除了“整个两阶段编排没有运行”和“图片服务全局不可用”。

## 代码根因

### P0：供应商提示词仍是用户整句原文

`agent_runtime.dart` 当前通过：

```dart
String preserveVisualPrompt(String request) => request.trim();
```

保留整句语义，然后由 `agentImagePrompt` 添加教学信息图前缀，最终把包含人物姓名、交互指令和文字交付要求的整句请求发送给图片供应商。

“保留用户语义”本身是正确目标，但这里缺少中间层：

```text
原始用户需求
  -> 交付物语义
  -> 结构化 VisualBrief
  -> 供应商图片提示词
```

原始文本不能同时充当交付计划、文字任务和图片提示词。

### P0：Remote Agent 的终态在检查产物前被写死

`api.dart` 的 Remote Agent 路径在 `runAgentTurn` 返回后直接写入 `completed`，随后才读取任务图片产物。图片阶段在运行时内部捕获异常并保留文字，因此外层没有异常可用来纠正状态。

此前为普通任务 API 增加的 `partially_completed` 逻辑没有覆盖 Remote Agent 路径。这正是视频里“图片消失但显示已完成”的直接原因。

### P1：供应商错误结构被压扁

`image_service.dart` 只保留 `error.message`，没有保存：

- 方舟错误码，例如 `InputTextSensitiveContentDetected.PolicyViolation`
- HTTP 状态
- Ark Request ID
- 错误来源与是否可重试

结果是 UI 只能得到一段字符串，无法决定“换输入”“换供应商”“稍后重试”或“继续保留文字”。

### P1：技能工具被无条件开放

只要账号里存在任何技能，普通问答和混合文字+图片任务就会挂载 `skills()` 中间件并开放技能工具。官方中间件还会注入“Strongly prefer to use skills”的系统提示，与项目的“常规知识问答不调用技能”冲突。

此外：

- 工具字段叫 `skillName`，实际查找的是临时目录 basename，即技能 ID。
- 系统目录同时展示显示名和 ID，模型容易先传显示名。
- `read_skill_resource` schema 把 `skill_id` 声明为可选，但自动技能路径又要求它必须存在。
- 成功 `use_skill` 后没有保存本轮 `activeSkillId`。

这会造成主题相关时才出现的工具调用抖动。它不是本次图片 400 的直接原因，但应与图片链路一起修复。

## 为什么其他 Agent 可以生成

不同 Agent 使用的图片供应商及人物政策并不相同。

- ModelArk 官方说明其过滤器可能阻止生成与政治、体育、商业、娱乐和媒体公众人物相似的图像。
- 火山方舟错误表明确列出 `InputTextSensitiveContentDetected.PolicyViolation`，对应“输入文本可能涉及版权限制”。
- OpenAI 的原生图像系统采用更细粒度的成人公众人物政策，并允许教育、历史和讽刺等用途；它还公开返回主模型改写后的 `revised_prompt`。
- Google Imagen 提供 `personGeneration` 参数，部分模型的 `allow_adult` 明确包括名人。

所以“Codex 可以生成”并不能证明 Seedream 会接受同一原始提示词；它证明多供应商路由和可观察的提示词编译层有实际价值。

## 通用修复方案

### 1. 引入结构化 `VisualBrief`

图片阶段只接受经过校验的简报，不再接受整个用户原句：

```text
VisualBrief:
  deliverable_id: string
  semantic_goal: string
  subjects: string[]
  relations: string[]
  required_facts: string[]
  required_text: string[]
  depiction_type: infographic | diagram | illustration | portrait | scene
  people: none | generic | named_public_figure | private_person
  likeness_required: boolean
  attribution_context: string[]
  forbidden_changes: string[]
  provider_prompt: string
```

关键规则：

- 人名是知识来源，不等于画面主体。
- 用户只要求“用图解释概念”时，图片表达概念结构，不生成人物肖像。
- 用户明确要求画某位公众人物时，`likeness_required=true`，不得静默删掉主体或伪装提示词；根据供应商能力路由或公开说明限制。
- 生成器输入要符合 Seedream 官方建议：简洁、连贯的自然语言，明确主体、行为、环境、风格与构图，中文建议不超过 300 字。

当前示例应编译为：

```text
semantic_goal: 解释第一性原理的推理过程
depiction_type: infographic
people: none
likeness_required: false
subjects:
  - 表面问题
  - 基础事实
  - 拆解步骤
  - 从基础事实重新构建方案
provider_prompt:
  竖版教育信息图。用四个连续模块展示第一性原理思考流程：识别问题、质疑既有假设、
  拆解到不可再简化的事实、从基础事实重新构建方案。使用清晰箭头连接各模块，
  现代简洁的信息图风格，不出现人物肖像、品牌标志或名人姓名。
```

这不是规避审核，因为用户没有要求画马斯克本人；它是在图片交付物中准确表达用户真正需要理解的概念。

### 2. 把混合任务改成确定性阶段机

```text
plan
  -> text_generate
  -> text_persisted
  -> visual_brief_compile
  -> provider_select
  -> image_generate
  -> artifact_persisted
  -> verify
  -> final_status
```

硬约束：

- 文字模型回合不开放图片工具。
- 普通知识问答和普通混合任务不开放技能工具。
- 图片阶段由应用代码执行，不由模型决定是否调用。
- `text_persisted` 是图片阶段的依赖；图片失败不能删除文字。
- 只有图片产物成功入库后，图片交付物才能标为完成。

Genkit Dart 的 `defineCustomAgent` 适合这种需要多阶段、手工状态与自定义进度的流程；Agent/Skills API仍处于 Preview，应把关键交付顺序放在应用状态机中，而不是依靠开放式工具循环。

### 3. 增加供应商能力路由

维护服务端能力表：

```text
ProviderCapability:
  provider
  model
  supports_public_figure_adults
  supports_no_people_mode
  supports_prompt_rewrite
  exposes_revised_prompt
  safety_reason_detail
```

路由规则：

- `people=none`：优先使用 Seedream 的概念图提示词。
- `named_public_figure && likeness_required=false`：从图片提示词移除仅作为出处的人名，保留概念语义。
- `named_public_figure && likeness_required=true`：使用明确允许该请求的已配置供应商；若没有，返回真实限制。
- 不在供应商间盲目重试同一个被拒绝的提示词。

### 4. 使用结构化错误与正确终态

供应商适配器返回：

```text
ImageProviderError:
  origin: provider
  http_status: 400
  provider_code: InputTextSensitiveContentDetected.PolicyViolation
  provider_request_id: ...
  category: image_policy_blocked
  retry_policy: never_same_prompt
  safe_message: 当前图片供应商拒绝了该图片描述；文字内容已经完成。
```

任务终态：

- 文字成功、图片成功：`completed`
- 文字成功、图片政策拒绝：`partially_completed`, reason=`image_policy_blocked`
- 文字成功、图片暂时失败：`partially_completed`, reason=`image_provider_unavailable`
- 图片是唯一交付物且失败：`failed`
- 任务取消：`cancelled`

Remote Agent 与普通任务 API必须使用同一个终态计算器，不能各自实现一套。

### 5. 收紧技能路由

- 增加 `skill_mode = none | selected | routed`。
- 普通问答与普通混合任务使用 `none`，不挂载 `skills()`。
- 用户显式选择技能时，服务端直接加载唯一技能，不再暴露 `use_skill`。
- 自动路由先用结构化分类器选出一个精确 `skill_id`，主阶段只加载该技能。
- 成功加载后绑定 `activeSkillId`；`read_skill_resource` 仅接受 `path` 并使用绑定 ID。
- 每轮最多一次技能加载和一次 ID 纠错；资源缺失后关闭技能工具并继续完成主任务。

## 重试与幂等

- 400 政策/输入错误：不使用相同提示词重试。
- 429、网络超时、5xx：指数退避并加入抖动，受总时限和最大尝试次数约束。
- 幂等键：`task_id + deliverable_id + brief_hash + provider + model`。
- 先查询已有 attempt/产物，再决定是否重新调用供应商。
- 记录 `attempt_started`、`provider_accepted`、`artifact_stored`、`verification_completed`，不能用一个布尔值代表全部阶段。

## 可观测性

每次图片调用至少记录：

- task/turn/deliverable/attempt ID
- 原始需求摘要或哈希
- VisualBrief 版本和哈希
- 最终 provider prompt 哈希；受控诊断环境保存限期明文
- provider/model
- HTTP 状态、provider code、Request ID
- 延迟、重试次数、产物数量与 artifact hash
- 最终终态和失败来源

不要在普通日志打印密钥、完整附件、Base64 或全量历史。

## 验收矩阵

至少覆盖以下任务：

| 用例 | 预期 VisualBrief | 预期结果 |
|---|---|---|
| 讲解光合作用并配图 | 植物过程图，无人物 | 文字后图片，完成 |
| 讲解马斯克第一性原理并配图 | 第一性原理信息图，无人物、无需姓名 | 文字后图片，完成 |
| 生成马斯克肖像 | 公众人物、需要相似度 | 按供应商能力路由或明确说明限制 |
| 讲解牛顿第一定律并配图 | 力与运动示意图，无人物 | 不因“牛顿”姓名触发肖像路径 |
| 图片供应商返回 400 政策错误 | 结构化不可重试错误 | 保留文字，`partially_completed` |
| 图片供应商返回 429/5xx | 可重试错误 | 有界退避，不重复落库 |
| 账号存在相关技能的普通混合任务 | `skill_mode=none` | 不出现 `use_skill/read_skill_resource` |
| 技能资源缺失 | 技能失败熔断 | 文字仍完成；需要图片时继续图片阶段 |

验收必须检查实际事件顺序、供应商请求、错误码、任务终态和产物，不以“提示词看起来合理”作为通过标准。

## 实施顺序

1. P0：VisualBrief 编译器与 Remote Agent 统一终态计算。
2. P0：结构化 Ark 错误解析，UI 展示部分完成及恢复动作。
3. P1：技能模式和资源读取契约修复。
4. P1：供应商能力路由、幂等与有界重试。
5. P1：生产 A/B 回归集和指标看板。

## 参考资料

- [ModelArk Content Filter FAQ](https://docs.byteplus.com/en/docs/modelark/content_pre_filter_faq)
- [火山方舟错误码](https://docs.volcengine.com/docs/ark/error-codes?lang=en)
- [Seedream 4.0–5.0 提示词指南](https://docs.volcengine.com/docs/ark/seedream-4-0-5-0-prompt-guide?lang=zh)
- [Seedream 图片 API：建议提示词长度](https://docs.volcengine.com/docs/LakeAIService/ImagegenerationSeedreamseriesmodels?lang=en)
- [OpenAI 原生图像生成系统卡](https://cdn.openai.com/11998be9-5319-4302-bfbf-1167e093f1fb/Native_Image_Generation_System_Card.pdf)
- [OpenAI Image Generation：revised_prompt](https://developers.openai.com/api/docs/guides/image-generation)
- [Google Imagen 人物生成与安全设置](https://cloud.google.com/vertex-ai/generative-ai/docs/image/configure-responsible-ai-safety-settings)
- [Genkit Agent 错误处理](https://genkit.dev/docs/agents/errors/)
- [Genkit 官方仓库](https://github.com/genkit-ai/genkit)

