# Genkit Dart 真机问题调查与解决方案

调查日期：2026-10-10。下文时间均为北京时间（UTC+8）。

## 先看这段：到底出了什么问题？

**建议保留 Genkit，先修迁移时没有接好的接口。现有证据已经能解释失败、看不到图片和回答结束后仍然等待；暂时没有依据要求更换模型或重做架构。**

| 你遇到的问题 | 大白话解释 | 证据程度 |
|---|---|---|
| 时好时坏、提示任务失败 | 模型一旦调用工具，就可能碰到不完整的参数说明或错误的工作目录；直接回答时又可以成功 | 已取得对应失败记录；两次参数错误的具体入参未留存 |
| 发了图片却说没收到 | 图片到达服务器了，但服务器交给 Agent 前把消息转成纯文字，图片被丢掉 | 已确认 |
| 普通问答也扯到技能、脚本 | 每轮都塞入技能目录，默认提供执行工具，却没有给聊天 Agent 接上读取技能的工具 | 代码与任务输入已确认；不是每次提到技能都代表实际调用了工具 |
| 回答完仍在等待，不能继续发送 | 服务端说 `completed`，客户端只认 `succeeded`，两边对“完成”的叫法不同 | 已确认，日志显示完成后仍持续轮询 |
| 曾经完全切换不了模型 | 不能直接归因于上面的问题：当前源码允许生成过程中选择模型 | 尚未复现，缺少当时客户端状态日志 |

调查阶段完成了服务器和真机只读调查、源码核对、官方资料研究；当时尚未修改业务代码或部署修复。后续实施和验收记录见文末。

## 1. 为什么“总是失败，有时又正常”？

### 实际查到了什么

这次测试时段内共找到 8 个新任务：3 个失败、3 个完成、2 个取消。取消不计为失败，也不能把这 8 次当成整体成功率。

| 任务开始时间 | 输入 / 模型 | 服务端结果 |
|---|---|---|
| 09:44:41 | 讲解马斯克第一性原理 / MiMo | Python 工具参数校验失败，6 秒后结束 |
| 09:45:02 | 同类问题 / MiMo | 61 秒后完成，输出完整讲解 |
| 09:48:47 | 图片＋“这是什么” / MiMo | Python 工具参数校验失败，4 秒后结束；对应图一时间 |
| 09:49:10、09:49:46 | “你好” / DeepSeek；图片提问 / MiMo | 分别 2 秒、6 秒后完成；第二次回答说没收到图片 |
| 09:50:57、09:51:33、09:52:03 | 继续生成 / MiMo；第一性原理 / DeepSeek；图片提问 / DeepSeek | 前两次取消；最后一次因写入只读目录失败 |

前两次失败的原始错误相同：

```text
AgentError(INTERNAL): tool "execute_python" failed:
FormatException: 代码不能为空且不能超过 64 KB
```

**严格来说，这条错误同时涵盖“代码为空”和“代码太大”。** 没有工具原始入参，无法从这一条日志区分两者。以下源码问题则是确定存在的：

- 聊天 Agent 的三个工具都没有声明 `inputSchema`，也就是没有告诉模型：参数叫什么、什么类型、哪些必填。
- `execute_python` 实际从 `input['code']` 取代码，缺少该字段就替换成空字符串。
- 我核对了部署锁定的 `genkit_openai 1.0.0` 发布源码：没有输入 schema 时，插件会把工具参数声明为 `{"type":"object","properties":{}}`。

**相当于给模型一张空白表格，却要求它必须填入一个叫 `code` 的栏目。** 空参数是强嫌疑，但不能冒充已经记录到的事实。Genkit 官方工具示例明确展示了 `inputSchema` 的用法。[官方 OpenAI 工具说明](https://genkit.dev/docs/dart/integrations/openai/)

第三次失败更直接：

```text
os.makedirs('/home/user/workspace/output', exist_ok=True)
OSError: [Errno 30] Read-only file system: '/home/user'
```

工具说明仍告诉模型工作目录是 `/home/user/workspace`；新 Docker 沙箱真正可写的工作目录是 `/workspace`，产物目录是 `/workspace/output`。模型照着错误说明写文件，被沙箱正确拒绝了。

### 应该怎么修

为三个工具补完整参数定义和边界校验；把说明、执行器、技能资源里的目录统一为 `/workspace`。可修正的参数错误应返回明确、有限的纠错信息，让模型有机会修正；不要对已经产生副作用的工具无脑重试，也不要取消沙箱只读保护来掩盖路径错误。

这能解释“同一句话有时成功、有时失败”：**回答路径不同，触发工具后才踩到工具链缺陷。** 不应先把它归为密钥失效、服务器没启动或模型随机抽风。

## 2. 为什么两个视觉模型都“看不到图片”？

### 图片确实已经上传

09:48:47 和 09:49:46 两个任务的服务器存档都包含：

```text
content:
  text: 这是什么
  image_url: data:...base64,...
```

两次图片 data URL 长度均为 713,622 个字符。09:52:03 的 DeepSeek 请求也有图片，长度为 651,890 个字符。报告没有保存或展示图片的 Base64 内容。

真正丢图的位置在 `agent_runtime.dart`：

1. 遍历所有消息，将它们拼成“用户：…… / 助手：……”的长字符串。
2. `_textContent()` 只读取每个内容块的 `text`，忽略 `image_url`。
3. 最终调用 `chat.sendStream(text: conversation)`，只传文字。

**上传成功不等于模型收到图片。这里是服务器的消息转换丢图。**

同一段转换还把 `system` 消息标成“用户”，并把多轮消息的真实角色变成普通文字标签，削弱了对话结构和指令边界。

### 应该怎么修

保留 Genkit 原生 `Message`、角色和内容块；图片转换为 `MediaPart`，文字转换为 `TextPart`。最新输入通过支持多模态的 `message` 参数发送，历史记录通过 Agent 的消息/会话机制提供，不能继续拼成单个字符串。

项目的 `chat_completion_service.dart` 已经有角色映射、图片格式校验和 `MediaPart` 转换，应复用这部分逻辑，避免两条聊天入口行为不同。保留图片格式、总大小及来源校验，不能只修“能传过去”。Genkit 官方多模态接口要求传入媒体内容块。[Genkit 多模态说明](https://genkit.dev/docs/dart/models/#multimodal-input)

模型能力方面，你的判断有官方依据：DeepSeek 文档明确 `deepseek-flash` 接受图片；小米官方说明 MiMo-V2.6 Pro、Flash 都是原生多模态模型。[DeepSeek 视觉文档](https://api-docs.deepseek.com/guides/vision/)、[MiMo-V2.6 官方说明](https://mimo.mi.com/docs/en-US/news/latest/v2-6)

不过，本轮没有重新发起收费模型调用；**修复后的真实识图仍须用两家实际 API 分别验收**，包括多轮图片和切换模型后的历史图片。

## 3. 为什么普通聊天也要“用技能”？

### 不是只有一个提示词问题

查到三个接线问题：

1. **每一轮都附带整个技能目录。** 即便输入只是“你好”，也会带上看图写寓言、哲学讲解、文字生图，并写着“若有，优先使用其内容”。哲学技能的描述覆盖“有思想深度的讲解”，范围很宽，第一性原理容易被匹配进去。
2. **目录与实际工具脱节。** 聊天 Agent 只注册 `generate_image`、`execute_python`、`execute_skill_script`。`list_skills`、`read_skill_resource`、`read_task_material` 等在另一个 MCP 服务中，聊天 Agent 没有连接它们。MCP 服务部署成功，不等于聊天模型能调用里面的工具。
3. **没有选技能，仍然提供执行技能脚本的工具。** 本时段 8 个任务的 `capability` 都为空；因此自动匹配到的名称，没有变成可执行的技能 ID、版本和文件授权。模型可能绕去用 Python 找目录，或者只根据目录描述声称“正在使用技能”。

云端核查结果：哲学技能存在，包含 `SKILL.md`；看图寓言技能也是只有 `SKILL.md`；生图技能另有 `scripts/generate_image.py`。**文字型技能没有脚本很正常，不代表同步失败，更不应该先找 Python 脚本才开始回答。**

图三中的“先看看目录”“落盘到 output”并不是解释第一性原理必须做的事。它反映出模型被引导向执行任务，却没有获得一致的技能读取和执行能力。

还要区分：09:49:10 的“你好”回答列出技能，本身不能证明实际执行了技能；而三个失败任务的异常明确证明进入了 `execute_python`。当前事件流缺少工具调用记录，不能仅凭模型的自述判断执行了什么。

### 建议的行为规则（待实现前确认）

| 用户需求 | 预期行为 |
|---|---|
| “你好”、一般知识问答 | 直接回答；不主动检查目录、跑代码或写文件 |
| 图片＋“这是什么” | 直接用视觉理解，不自动套用“写寓言”或生图技能 |
| “讲解第一性原理” | 默认直接讲解；不为了讲解去执行脚本或生成文件 |
| 明确点选技能，或请求明显匹配技能用途 | 先读取真实的技能指令；文字技能可以只生成文字 |
| 明确要计算、处理文件、生成图片等 | 提供所需工具；仅在工具确实有帮助时执行 |

不建议另加一个复杂的“总调度 Agent”。先收紧技能用途、按需加载真实技能文件，并让“模型看见的工具”和“服务器实际可用的能力”一致。已在项目中的 MCP 工具可以共享实现，但需保留用户、任务和技能版本的访问边界，不能直接扩大权限。

这符合行业常见做法：从简单调用开始，确有需要再增加 Agent 步骤；工具说明和参数接口本身也要认真设计与评估。[Anthropic：构建有效 Agent](https://www.anthropic.com/engineering/building-effective-agents)、[工具设计实践](https://www.anthropic.com/engineering/writing-tools-for-agents)

## 4. 为什么回复完不能继续发？模型切换又是什么情况？

### “一直等、不能发”有完整证据

服务端成功时保存：`status = completed`。

客户端 `watchTask()` 只在 `succeeded / failed / cancelled` 时结束等待。虽然它收到名为 `completed` 的事件并暂存了答案，但没有退出轮询，所以 `_sendMessage()` 的收尾逻辑迟迟不执行，`_isGenerating` 继续为真。

服务端访问日志证实了这个问题：

| 服务端已完成的任务 | 完成时间 | 完成后仍然查询事件的次数 |
|---|---|---|
| 第一性原理讲解 | 09:46:03 | 297 次，持续到 09:48:23 |
| “你好” | 09:49:12 | 400 次，持续到 09:52:27 |
| “这是什么” | 09:49:52 | 332 次，持续到 09:52:27 |

**服务器已经答完，手机还在问“答完了吗”。** 源码中的轮询预算是 20 分钟；另外 `getTask()`、`getTaskEvents()` 的单次 HTTP 请求没有显式超时，网络请求卡住时，循环外层的时间判断也不能及时救场。

这也解释了截图中的等待圆点、停止按钮，以及用户点停止后出现“已停止／继续生成”的现象。但没有逐次点击轨迹，不能断言每个“已停止”都由同一原因造成。

### 模型切换：这里必须保留边界

当前源码 `_setSelectedModel()` 没有因 `_isGenerating` 而禁止选择模型；它只在删除回复或保存消息编辑时直接返回。已经启动的请求使用发送时的模型，之后选择另一个模型不会把正在运行的那次请求换掉。

所以应区分：

- **能选另一个模型，但发不了下一条**：已确认的完成状态错误可以解释。
- **模型菜单打不开或选择完全不生效**：现有证据不够，不能说已经查明。

我通过 ADB 只读检查了已连接的 TB335FC：安装包为 `1.0.0`、版本码 `5`，最后更新时间是今天 09:43:59。调查时应用进程已退出；旧进程保留下来的日志只覆盖约 10:03:21 至 10:03:40，没有首次卡住的 Flutter 异常或状态记录。本轮没有启动应用、操作界面或宣称真机复现成功。

### 应该怎么修

先统一任务状态契约。为了照顾已经安装的客户端，**建议服务端对外恢复使用旧的成功状态 `succeeded`，事件名仍保留 `completed`；新客户端过渡期兼容两种成功状态。** 数据读取时统一映射，避免修改历史任务数据。

同时修好正常发送、停止确认、恢复任务、继续生成的所有终态判断；增加单次请求超时、有限重连、终态兜底与本地取消订阅。成功、失败、取消和断线都应能结束当前 UI 的等待。断线时保留任务 ID 便于恢复，不能把网络断线直接当成任务失败。

## 5. 为什么部署和测试通过了，真机还有这些问题？

**之前主要证明了服务能启动、接口能访问、沙箱能执行；没有证明真实聊天链路已经正确连接。**

迁移记录明确写着候选容器使用 fake generator，没有真实模型调用，也没有完成邮箱会话下的真机聊天验收。现有 API 测试的 `_FakeRuntime` 直接返回“你好”，服务端测试认 `completed`，客户端却认 `succeeded`，两者没有在同一条验收链路中对照。

此次读取的应用容器日志，在 09:40—10:00 共 1,378 行，未匹配到异常或 HTTP 500/503。三个业务失败藏在任务数据库的 `error` 字段里，查询任务接口依然返回 HTTP 200，所以只看容器健康和 HTTP 状态会误判。

调查时应用与沙箱容器健康；应用容器 `OOMKilled=false`，启动于 09:27:42，没有发现本次失败时重启的证据。上述三个错误已有明确应用层原因。

Genkit 的 Agent API 文档仍标记为 Beta。它提供失败状态、快照和中断恢复机制，但应用必须正确接收并持久化这些信息；当前代码每个任务新建内存会话，再把异常压成一条通用提示，相关诊断信息没有完整保留下来。[Genkit Agent 概览](https://genkit.dev/docs/dart/agents/overview/)、[Agent 错误处理](https://genkit.dev/docs/dart/agents/errors/)

## 修复顺序：先恢复可用，再验证稳定

| 顺序 | 工作内容 | 必须看到的验收结果 |
|---|---|---|
| 1 | 统一终态；修复轮询、停止、恢复和超时 | 正常回答后无需点停止即可继续发送；成功任务不再持续轮询；旧任务可读取 |
| 2 | 保留角色与多模态消息；复用现有转换逻辑 | 两个实际模型都能识别同一测试图；多轮追问、换模型后图片仍正确 |
| 3 | 补工具 schema；统一 `/workspace`；处理可恢复工具错误 | 参数字段明确；无效参数有清晰错误；合法脚本可写产物，且只读与网络限制不变 |
| 4 | 收紧技能匹配，接通真实技能读取，按需提供工具 | 问候和普通讲解不执行脚本；显式技能请求读取正确版本；没有脚本的文字技能正常工作 |
| 5 | 补关联日志与贯穿前后端的验收 | 每次请求能追到模型、工具、错误分类和终态；失败、取消、断线恢复、重启均有证据 |

日志建议记录任务 ID、实际模型 ID、消息角色和图片数量、工具名、参数字段与长度、耗时、错误分类及终态。**不记录 API 密钥、登录令牌、图片 Base64 或完整私人内容。** 对用户显示可理解的失败类型和查询编号，不把服务器堆栈直接展示出来。

修复应沿用现有任务接口、SQLite 数据和 Docker 沙箱。先在隔离候选环境验证，再部署兼容旧客户端的服务端，最后更新客户端。保留旧镜像用于回滚；新增状态映射不需要清空或迁移用户数据。持久化 Agent 快照、联网中断恢复可作为随后补齐的可靠性工作，不能用内存会话宣称已经支持进程重启后的自动续跑。[Genkit 会话存储](https://genkit.dev/docs/dart/agents/session-stores/)、[Genkit 中断与恢复](https://genkit.dev/docs/dart/agents/interrupts/)

**验收时要分别记录：代码完成、自动化检查通过、真实模型调用通过、真机交互通过、已部署。不能再用其中一项代替其他项。** 真机自动化测试如需编写，按项目规范先用 ARTEMIS 探索并确认交互路径；本次没有编写此类测试。

## 证据索引（供实施时直接定位）

### 核心源码

| 位置 | 对应问题 |
|---|---|
| [agent_runtime.dart:182](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/agent_runtime.dart:182)、[同文件:378](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/agent_runtime.dart:378) | 历史消息转字符串、丢弃图片及角色 |
| [agent_runtime.dart:65](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/agent_runtime.dart:65)、[同文件:208](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/agent_runtime.dart:208) | 缺少工具 schema、旧工作目录、仅注册三个工具 |
| [api.dart:608](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/api.dart:608)、[capability_cloud_sync.dart:457](/C:/Users/20833/Desktop/xiaoqi_app/lib/features/capabilities/data/capability_cloud_sync.dart:457) | `completed` 与 `succeeded` 不一致；客户端轮询无法结束 |
| [home_page.dart:1991](/C:/Users/20833/Desktop/xiaoqi_app/lib/pages/home_page.dart:1991)、[mcp_server.dart:64](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/mcp_server.dart:64) | 技能目录注入；技能读取工具只存在于独立 MCP 服务 |
| [chat_completion_service.dart:166](/C:/Users/20833/Desktop/xiaoqi_app/xiaoqi_harness/genkit_server/lib/src/chat_completion_service.dart:166)、[home_page.dart:1055](/C:/Users/20833/Desktop/xiaoqi_app/lib/pages/home_page.dart:1055) | 可复用的多模态转换；模型切换实际逻辑 |

### 服务器与版本

通过现有阿里云身份、云助手执行只读查询，检查香港 ECS 上的应用、沙箱执行器和 Caddy 日志，并以 SQLite `mode=ro` 读取任务记录和输入对象。

生产镜像：`xiaoqi-genkit-server:local`，镜像 ID：

```text
sha256:1637c40a7e426cc7840b3dd991c6f35ff25b0ca5862a47a806d65fd2a62903f2
```

服务器部署目录与本地对应文件 SHA-256 一致：

| 文件 | SHA-256 |
|---|---|
| `agent_runtime.dart` | `03d2c160cc41b57512698a33ab1a31bfb88a2754200a23130aa2196b80334f2d` |
| `api.dart` | `61b5fec4f278ec80491c1980caab029543574c2ee6a70c246eb6373e045a50fe` |
| `sandbox_runner/server.py` | `f0ccb95a58258690c5ccffad03266b6955e7a91c8c7d46eff3995583a0929bcd` |
| `pubspec.lock` | `6c7e74d0d3926e43bb4792aacf4319aa46b786275e64588f97e303c1b6532d8e` |

部署依赖锁定为 `genkit / genkit_openai / genkit_mcp 1.0.0`。发布源码核对使用 [genkit 1.0.0](https://pub.dev/packages/genkit/versions/1.0.0) 和 [genkit_openai 1.0.0](https://pub.dev/packages/genkit_openai/versions/1.0.0) 的官方包归档；其中 `genkit_openai/lib/src/converters.dart:234` 可核对缺省工具参数行为，`genkit/lib/src/ai/agents/agent_core.dart:819` 可核对 `sendStream(message: ...)`。

| 关键任务 | ID |
|---|---|
| 第一性原理参数失败 | `task-268ab4c4e7e7c63757c5e481` |
| 图一图片任务失败 | `task-893286400bbdd3dd3699c743` |
| “你好”完成但仍轮询 | `task-68de243daa3c897c03d4a800` |
| 图二回答“没收到图片” | `task-12ce8fe93fb03873b2d40adc` |
| DeepSeek 写入只读目录失败 | `task-5e3149dbb85788f216eb4393` |

外部资料均于 2026-10-10 检索，用作说明和方案参考，本次未复制外部项目代码。现有证据足以启动前四类修复；首次“模型菜单完全失灵”仍须在真机复现时记录状态，不能标为已解决。

## 修复后验收记录（2026-10-10）

本地已完成任务状态兼容、图片与历史消息转换、按需开放工具、工具参数 schema、请求超时与安全日志等修复。

- Genkit 服务端：`dart analyze` 无问题，`dart test` 的 20 项测试全部通过；新增测试覆盖普通聊天不暴露技能工具、显式请求才开放对应工具、图片消息转换与图片输入校验。
- Flutter 改动文件：定向 `flutter analyze` 通过；`flutter build apk --debug --no-pub` 成功。
- 生产已部署镜像 `sha256:2fc3baa9b3175637e0a446d0ba49f7907ae264b9ec93f03f81c8b5e9bc6f56c7`；应用与沙箱容器均为 `running / healthy`，外部 HTTPS `/health` 返回 `{"status":"ok"}`。
- 部署前已备份数据卷至 `/opt/xiaoqi-single-server/backups/codex-hotfix-20261010/xiaoqi-data-before.tgz`；部署后对 SQLite 与对象文件清单进行前后比较，结果通过，未发现数据变化或丢失。
- **仍待你真机验收：**真实模型 API 的图片理解效果，以及首次出现的发送按钮变灰、不能切换模型问题。此次没有用真实模型发送请求，也没有连接真机，不能把这些标记为已验证解决。
- 调试 APK 已生成：`build/app/outputs/flutter-apk/app-debug.apk`。本次未进行 release 构建。
