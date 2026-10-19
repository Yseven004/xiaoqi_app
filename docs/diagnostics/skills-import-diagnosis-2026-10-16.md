# 三个 GitHub 技能的安装与运行问题：原因和解决方案

日期：2026-10-16。核查基线：本地代码 `b50a3d0`、用户提供的四张截图、三个仓库的公开源码。

**优先修复小栖的技能读取链路。重新选择、反复卸载重装、换语言模型，都不能消除已发现的代码缺陷。**

| 对象 | 当前失败环节 | 已确认原因 | 修复后还要验证 |
|---|---|---|---|
| good-learning | 聊天发送前 | 云端版本记录没有内联正文，客户端却把空正文当作版本不可读 | LaTeX 编译、中文字体、最终 PDF |
| study-notes-studio | 聊天发送前 | 同一处客户端读取缺陷 | 技能能否实际调用生图工具、返回笔记图片 |
| book-to-skill | 导入检查 | 文本关键词误判；只接受 requirements.txt 的依赖策略 | 文档提取、跨步骤文件保存、生成并注册新技能 |

**图四不是“已经尝试启动 MCP 然后失败”，也不是检查出手机缺了某个指定客户端组件。它是在执行之前，被小栖的静态规则拒绝了。** 小栖目前确实还没有接入通用 MCP 连接器，但 book-to-skill 的核心转换流程不以 MCP 为必需条件。

## 1. 为什么“安装成功”，聊天却提示“指定版本无法读取”

### 真实的数据路径

```text
服务端下载 GitHub 仓库并固定版本
  → 保存技能 ZIP 包
  → 安装记录保存 version_id、artifact_key、components
  → 手机缓存安装记录，市场显示“已安装”
  → 聊天准备消息时要求 version.content 非空
  → 因安装记录没有 content，抛出“指定版本无法读取”
  → 服务端 Agent 尚未收到这一轮任务
```

证据链如下，三个条件可以同时成立：**版本存在、包已经保存、手机端正文为空**。

1. [服务端安装记录](../../xiaoqi_harness/genkit_server/lib/src/capability_import_service.dart#L725)：第 725–743 行保存 ZIP，并写入版本的 `artifact_key`、`components` 等字段，**没有 `content` 字段**。
2. [客户端反序列化](../../lib/features/capabilities/data/capability_models.dart#L34)：第 39 行将缺失的 `content` 变成空字符串。安装结果通过 [runImportOperation](../../lib/features/capabilities/data/capability_cloud_sync.dart#L985) 原样进入该模型。
3. [聊天校验](../../lib/pages/home_page.dart#L2953)：第 2961 行把“找不到版本”和“正文为空”合并判断；两者都抛出截图中的同一句错误。
4. [发送顺序](../../lib/pages/home_page.dart#L1946)：先 `_buildAiMessages`，成功后才 `_runAgentTaskReply`。因此不能把这个报错归因于 DeepSeek、MCP 启动或技能脚本执行失败。
5. [服务端 SelectedSkills](../../xiaoqi_harness/genkit_server/lib/src/selected_skills.dart#L16) 已有按安装 ID、固定版本和组件读取技能包的正确路径；客户端提前报错，让它没有机会工作。

**问题属于安装数据与聊天使用方式没有接通。提示文案还把“正文为空”误导成了“版本读不到”。** 按当前实现，新导入的其他 GitHub 独立技能也会遇到同类问题，并非这两个仓库恰好都有坏版本。

### 建议修复

- 对服务端管理的技能，手机保留并提交完整的安装 ID、固定版本 ID、组件选择；不要要求手机缓存整份 `SKILL.md` 才能发起任务。
- 服务端继续校验账号、启用状态、固定版本和包完整性，再经 `use_skill` / `read_skill_resource` 加载正文。不能用“忽略报错然后普通聊天”冒充执行技能。
- 区分“版本不存在”“包缺失/损坏”“账号不匹配”“技能已停用”等真正错误；禁止悄悄切换到最新版。
- 检查所有发送入口，包括首次发送、重试、编辑后重发和多技能选择。若现有服务端技能包完整，客户端修复后原则上可以复用安装记录，无需重新下载；是否完整仍需读取实际账号记录确认。

这里的“技能固定版本”也不是应用的 API contract version。应用已有的客户端/服务端版本匹配检查，无法发现字段语义使用错误。

## 2. book-to-skill 为什么被禁止安装

按截图中的固定提交 `a24e62f4d8caf2ee433f6e48d9073800f56f906e` 核对，两个拒绝理由均能从本地检查器与上游文件对上。

### A. MCP / 专有客户端提示：发生了误判

[检查器第 536–540 行](../../xiaoqi_harness/genkit_server/lib/src/capability_import_service.dart#L536) 对整份 `SKILL.md` 做关键词匹配，包括 `MCP` 和 `Claude Code only`，命中就判不支持。它没有区分必需依赖、说明文字、注释和条件分支。

对该固定提交执行等价正则检查，命中两处：

| 上游位置 | 原意 | 小栖的判断问题 |
|---|---|---|
| SKILL.md 第 17 行 | 注释说明不同宿主怎样命名工具，强调不绑定某个 Agent | 出现 MCP 字样便拒绝 |
| SKILL.md 第 641 行 | 仅在 Claude Code 宿主下处理目录发现/软链接 | 将条件说明里的客户端名称当成整个技能的硬依赖 |

上游明确需要的是**运行 Python 提取器，以及文件读写能力**；不要求先启动一个特定 MCP 服务。[固定提交的技能说明](https://github.com/virgiliojr94/book-to-skill/blob/a24e62f4d8caf2ee433f6e48d9073800f56f906e/SKILL.md)

**解决办法：** 按结构化工具声明、真实配置文件及必需执行路径判断依赖。仅在文档出现名称时给出提示，不能直接禁止安装；真正依赖当前未提供工具的技能仍需明确阻止或说明受限范围。

### B. requirements.txt 提示：小栖支持的依赖格式太窄

[检查器第 555–557 行](../../xiaoqi_harness/genkit_server/lib/src/capability_import_service.dart#L555) 规定：只要有 `pyproject.toml` 而没有 `requirements.txt`，就拒绝。

但这个仓库使用标准 Python 项目描述：版本为 1.4.0，要求 Python ≥3.9；提取格式对应的库列在 `project.optional-dependencies` 中。它并没有声明所有格式都必须安装全部可选库。[固定提交的 pyproject.toml](https://github.com/virgiliojr94/book-to-skill/blob/a24e62f4d8caf2ee433f6e48d9073800f56f906e/pyproject.toml)

| 输入能力 | 上游运行要求 | 建议接入方式 |
|---|---|---|
| TXT、Markdown | 标准库即可 | 作为首个端到端验证样例 |
| 普通文字 PDF | pdftotext、pypdf、pdfminer 等可用路径之一 | 为支持的提取路径准备并固定依赖 |
| EPUB、DOCX、HTML | 有可选增强库及部分标准库回退 | 验证真实样例和提取质量后标记支持 |
| 技术文档、表格/公式较多的 PDF | Docling 增强路径 | 单独评估模型资源、内存、执行时长 |
| MOBI/AZW；扫描 PDF | 前者需要 Calibre；后者需要 OCR 预处理 | 明确能力边界，不能声称装上技能就全格式可用 |

这些是上游实际区分的运行路径，不是 MCP 依赖。[上游运行要求](https://github.com/virgiliojr94/book-to-skill/blob/a24e62f4d8caf2ee433f6e48d9073800f56f906e/README.md)

**解决办法：** 支持解析 `pyproject.toml` 的声明式依赖；区分运行依赖、可选依赖与构建依赖。沿用现有包来源校验和隔离安装，不能为了兼容而任意执行仓库构建脚本。安装阶段预备所选能力需要的包，不依赖无交互任务中临时回答 pip 安装询问。

## 3. 只放开“安装”按钮还不够

### book-to-skill 必须补齐的宿主适配

**建议把它作为小栖正式支持的云端技能接入，不要求 Android 自己运行 Python，也不先建设通用 MCP 平台。** 复用已有 Python 沙箱、技能版本绑定和技能保存流程。

1. **执行位置适配。** 上游搜索各类桌面宿主的技能目录；小栖实际将包挂载到 `/workspace/skill`。向 Agent 提供明确的脚本/资源地址，通过现有 `execute_skill_script` 调用 `scripts/extract.py`，保留完整 `book_to_skill/` 模块目录。
2. **跨步骤结果保存。** 当前每次脚本执行创建新容器和卷，结束后删除，仅收集 `/workspace/output` 产物。提取文本和 metadata 必须导出并可在后续步骤重新读取；只打印临时路径会导致下一步找不到文件。长书应有分块读取与持久化中间结果。
3. **生成结果注册。** 上游向桌面技能目录写文件，不会自动成为小栖“已安装”技能。输出应进入小栖技能草稿/保存通路，保存完整 `SKILL.md` 与章节、参考文件，随后能重新选择并使用；不要只生成一份无法再次调用的下载文件。
4. **保留原有校验。** 上游要求运行 `tools/scan_generated_skill.py`，小栖目前仅允许直接执行 `scripts/` 下入口。应提供经审查的入口适配或精确的允许列表，并保留检测逻辑，不能跳过扫描，也不能无限开放任意 shell。
5. **按能力准备资源。** 当前沙箱设置为 384 MB 内存、128 MB 临时盘、120 秒执行上限。不能直接承诺 Docling 能在此限制下处理整本技术书；需要实际基准验证后选择合适的任务资源、分块与恢复策略。

证据：[沙箱挂载与资源限制](../../xiaoqi_harness/genkit_server/sandbox_runner/server.py#L374)、[结束清理](../../xiaoqi_harness/genkit_server/sandbox_runner/server.py#L478)、[脚本路径限制](../../xiaoqi_harness/genkit_server/lib/src/agent_runtime.dart#L1998)、[上游提取入口](https://github.com/virgiliojr94/book-to-skill/blob/a24e62f4d8caf2ee433f6e48d9073800f56f906e/scripts/extract.py)。

可控的实施方式是保留固定上游提交，在小栖维护明确的宿主适配规则；必要时使用标明变更与来源的适配副本，保留 MIT 许可证。不要偷偷删除功能要求来换取“兼容”标签。

### 两个已安装技能的后续缺口

**good-learning：** 上游要求实际用 XeLaTeX 或 LuaLaTeX 生成 PDF，依赖中文排版宏包与字体；其 `requirements.txt` 仅包含可选 PNG 所需的 Pillow。当前 [sandbox_image/Dockerfile](../../xiaoqi_harness/genkit_server/sandbox_image/Dockerfile#L1) 仅安装 Python/pip 等基础组件，没有 LaTeX。因此“Python 依赖安装成功”不足以保证该技能完整运行。应在受控镜像加入所需编译器、宏包、中文字体，并验证 PDF 内容与渲染。[上游环境要求](https://github.com/yoli-mi/good-learning-skill#运行环境)

**study-notes-studio：** 上游默认要求 AI 图片生成，而非仅输出 Markdown 或用 Pillow/HTML 替代。[技能出图要求](https://github.com/yxxx6666/study-notes-studio/blob/main/SKILL.md) 当前 [agent_runtime.dart](../../xiaoqi_harness/genkit_server/lib/src/agent_runtime.dart#L779) 主要按用户文字判断图片意图，并可能提前走直接生图分支；工具选择也受该条件控制。需要让选中的技能能声明实际生图需求，先读取技能规定，再完成内容整理和图片生成。此处是代码层的后续风险，尚未做线上运行确认。

## 4. 推荐实施顺序与验收标准

| 顺序 | 交付 | 必须看到的验收结果 |
|---|---|---|
| 1 | 修复客户端错误要求本地正文 | 两个已安装技能可发起真实云端任务；服务端读取的版本与选择一致 |
| 2 | 修复 book-to-skill 误判及声明式依赖识别 | 固定提交可检查、安装；真正依赖未知工具的样例仍被正确拦截 |
| 3 | 接通 book-to-skill 文件与技能保存流程 | 小型 Markdown 和文字 PDF → 提取 → 生成多文件技能 → 保存 → 再调用成功 |
| 4 | 补齐另外两项输出能力及复杂格式 | good-learning 产出实际 LaTeX PDF；study-notes-studio 产出实际笔记图；复杂书籍格式逐项有验证证据 |
| 5 | 同一发布验证 | 客户端/服务端发布标识匹配；服务端部署、健康与数据检查完成；用户在手机验证原始入口 |

本次需求是排查并提出解决方案，因此没有直接扩展产品范围或修改生产代码。实施前需要明确 book-to-skill 首版支持的输入格式，以及生成技能的保存交互；这些决定影响资源和用户流程，不能默默降级为“只支持文本”。可以先以 TXT/Markdown/文字 PDF 做技术验证，但这不代表替用户决定最终范围。

## 5. 本次做到了什么，哪些仍未验证

- **已完成：** 对照四张截图定位代码，追踪安装记录到聊天发送的字段路径；读取三个上游仓库；对截图中的 book-to-skill 固定提交检查误判命中位置及依赖声明。
- **证据边界：** 前两个上游仓库读取的是检查当时的 main 文件，未取得手机实际安装的 SHA；核心客户端缺陷与这两个仓库的具体正文无关。没有读取用户手机缓存、线上安装包或 ECS 当前容器，所以不能把本地代码证据说成线上端到端复现。截图外层提示与当前源码措辞也有差别，手机具体构建版本仍需核对。
- **自动化检查：** 尝试运行现有 `dart test test/capability_import_test.dart --reporter expanded`；60 秒内仅得到构建 hooks / 加载测试的输出，未获得通过或失败结论。现有测试检查服务端安装读取与客户端标签保留，但所查测试没有覆盖“真实服务端安装记录 → 手机聊天准备”的完整链路。
- **未实施、未上线：** 尚未修复代码、安装 book-to-skill 或验证三个技能实际输出。未执行手机验证，待用户真机验证；本次没有可用 ARTEMIS 工具，按项目规则未诊断或安装 ARTEMIS。
- **server deployment not needed**：本次仅新增排查报告，没有修改生产服务、运行配置或 API 合约。后续实施若修改这些部分，应按项目规则由代理完成部署、健康/数据校验和失败回滚。

下一步：确定 book-to-skill 首版必须支持的文档格式与生成技能的保存方式，按上述顺序修复和验收。
