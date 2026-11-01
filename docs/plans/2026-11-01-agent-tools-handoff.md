# Agent 工具权限修复：暂停与跨窗口交接

更新时间：2026-11-01（Asia/Shanghai）。用户已恢复实施授权，并要求持续推进，不逐小步等待确认。下面旧窗口的暂停状态及未完成清单是历史基线，以本段和较新证据为准。

## 最新接续状态（先读本段）

**最终收尾状态（覆盖以下历史待办）**：范围内服务端修复与自动验收完成。
运行时源码 `1d160891871c4aaacf9f354538aebcf84790aea1` 的 CI `41310016481` /
job `124858224605` 成功：541 Dart 通过、6 个原生依赖跳过，95 runner、30 部署、
2 bridge、2 image 检查，官方 Apps 真实隔离容器及镜像导入导出均通过。
标准部署 `20261101-211115-1d16089` 的会话 `94454` 退出 0，无运行中部署需要重启。
精确产物/镜像、运行探针、健康/数据、流量恢复、清理、唯一 latest-good/data
验证通过，公开 HTTPS 经云助手 200，产品 `2026-11-01-agent-tools-apps`、API 25。
后续测试/文档提交不改变运行时，无需再部署。最终矩阵与边界见
`2026-11-01-agent-tools-current-matrix.md`、`2026-11-01-cross-entry-acceptance.md`，
发布证据 `evidence/2026-11-01-mcp-apps-release.json`。Android debug APK 构建、
23 项客户端既有回归通过；客户端真机未执行验证，待用户真机验证。
不得按以下旧清单重做功能或重复部署；欠费生图按用户要求后置且未调用。

Apps 接续：工作区已提交 `111190b`，正式 main 为 `1d160891871c4aaacf9f354538aebcf84790aea1`。
本地 547 项服务端回归、最终 12 项面板检查、服务端静态检查、Android debug APK、
23 项客户端既有回归通过。契约已同步为 25，产品 `2026-11-01-agent-tools-apps`。
官方 published Apps 2.0.4 的实际 stdio、原始 HTML/browser SDK 握手与刷新已跑通。
精确 CI `41310016481` / job `124858224605` 正在真实隔离 stdio 门禁。
部署控制器会话 `94454` 仍运行，日志 `%TEMP%/xiaoqi-apps-production.log`；
未确认终态前只读跟踪，不重复部署、不移动 main。
工作区额外测试/文档提交 `74361d4` 尚未同步 main：官方 reviewer 1 项、资源 3 项、
加强原预算断言的 Apps SDK 2 项通过，最终静态检查通过；无运行时行为变更。
当前矩阵已有未提交的证据汇总编辑。待本次激活/健康/数据/清理终态后更新证据，
再同步测试文档提交。手机未执行验证，待用户真机验证。

2026-11-01 后续核实：正式 main 为 `f42434bb9ca30ba4c467d565288e52834b879d76`，
CI `41304862195` / job `124843084510` 成功（529 Dart 通过、6 个原生依赖跳过，
真实隔离容器 gate 与镜像导入导出通过）。部署控制器会话 `89919` 已退出 0，
发布 `20261101-200636-f42434b` 健康，运行探针、数据/健康、流量恢复、清理与唯一
latest-good/data 已验证，公开 HTTPS 经云助手返回 200，API 24。
以下旧发布/生命周期待办已由此证据替代，勿重新部署或重新实现。
Apps 工作仍为未提交接续实现：12 项资源/实际 SDK/API 定向检查通过；
浏览器合成探针已验证握手、结果通知、跨源 DOM 隔离与网络阻断，尚非真实插件验收。
真实官方 npm 样本安装、取消通知边界、客户端编译、完整回归和下一批发布仍需完成。
客户端未执行验证，待用户真机验证。

- 正式 main 当前为 `4ce890b5314b10d7c8231ea6c7fd24dc9c1b045d`，已推送，正式目录干净。
- 最新已完整部署验证：`20261101-152921-4ce890b`，CI `41284972600` / job `124784897257`。508 Dart 通过、1 跳过；95 runner、30 部署、2 bridge、2 image 检查通过，真实 stdio gate 与镜像导入导出通过。发布控制器退出 0，运行探针、健康/数据、流量恢复、清理、公开 HTTPS 200、API 24 与唯一 latest-good/data 均验证。
- 已完成发布核实和旧 `67e29ef` 补部署；fork、DeepSeek V4.1 Flash（`deepseek-flash`）别名映射、动态命令上下文、会话级 skill tool Hooks/once 均已部署。不要按旧清单重新实现。
- 工作区已提交技能 Hook 发布证据 `620e6ca`，并接续 root SessionStart/UserPromptSubmit 生命周期实现与测试；本地源码以实际 git log/status 为准，尚未同步 main 或部署。
- 生命周期本地：18 项 catalog/lifecycle/journal/skill 状态检查、3 个实际 SDK 场景通过，随后完整定向回归 114 项通过，静态分析通过。日志 `%TEMP%/xiaoqi-lifecycle-regression.log`；会话 `33331` 已退出 0，无测试进程需继续等待。不要重复运行已通过检查，除非后续修改相关代码。
- 新 root 生命周期实现位于 `plugin_hook_lifecycle.dart`、`plugin_hook_event_journal.dart`；skill once 复用后者且保留原私有记录格式。真实 gate 已扩展到 16 code jobs / 11 Hook 成功，但此扩展未跑 CI。当前线上技能 Hook gate 是 14 jobs / 9 Hook 成功 / 3 独立 once。
- 后续本地已实现 Stop、任务所有的 async/asyncRewake、持久化后台恢复和条件过滤。完整回归 531 项通过；最后边界加强后 26 项定向检查、12 项队列/后台裁决/实际 SDK 检查及静态分析通过。混合容器 gate 目标为 18 jobs / 13 Hook 成功 / 5 文件，尚待精确 main CI。见 `2026-11-01-hook-lifecycle-followup.md`，不能当作已部署。
- 用户已确认必要 Apps 使用“聊天结果内展开（推荐）”，完整交互范围见 `2026-11-01-apps-interaction-review.md`，不用重复询问位置。已选真实官方 npm 样本 `@modelcontextprotocol/server-basic-vanillajs@2.0.4`，来源/完整性已记录，尚未执行或接入。必要 Apps/extensions、真实代表组合、跨入口剩余验收和最终矩阵仍开放。客户端未执行验证，待用户真机验证。不得把剩余项当作全部重新开发，也不得凭现有局部成功关闭 P01–P14。
- `2026-11-01-agent-tools-current-matrix.md`、各批 acceptance 文档及 `docs/architecture/evidence/2026-11-01-*-release.json` 为当前证据。
- 远端网络已用现有 `127.0.0.1:7890` 的进程级 HTTP(S)_PROXY 恢复稳定；不要启动新加速器或改系统配置。发布用 `pwsh -NoProfile`，避免旧 PowerShell 的 NativeCommandError；仍以 `deploy_current.ps1 -VerificationProfile non-image` 为唯一入口。
- 当前发布进程已退出 0，没有需要重复启动的部署。工作区后续改动未部署。不要移动 main 触发无必要的文档单独构建；将发布证据与下一批完整改动一起正常同步，确保下一批用精确 main 产物发布。

## 旧窗口基线（以下状态可能已被上述证据替代）

## 1. 目标、授权和范围

- 原目标：按照已确认的 P01–P14 方案完成 Agent 工具调用权限修复，既解决过粗限制，也修复安装、发现、执行、恢复、交付的实际阻断。
- 用户已经授权按方案持续实施，不需要重新询问是否开始；新窗口收到继续指令后接着完成。
- 已启用技能/插件的正常任务内行为应可执行；保留租户/任务/版本隔离、真实用户授权边界、撤权/取消、秘密保护、预算与审计。不能用全局无限权限、删掉错误提示、伪造成功代替适配。
- 对外发送、删除、付费等动作遵循已确认的具体授权策略；插件文档、模型推断、导入操作本身不能创造用户授权。
- P09 已按用户确认缩小为现有技能/插件和已有宿主适配；不开发通用电脑/手机控制，不买服务器或设备。
- 欠费生图服务按用户要求暂不处理，不调用、不要求充值、不阻塞其余工作；不能写成真实生图已验收。
- 用户不知道应选哪些插件；由 AI 选择真实/代表样本并记录来源、固定版本、许可证、依赖、组件、效果和证据，不再要求用户列名单。
- 不承诺兼容未来所有插件，也不能将已登记的必要组件简单标成“不支持”后关闭任务。新增 UI/产品决策遵循 AGENTS.md，不无声扩展范围。
- 客户端/真机验证由用户负责；未经用户验证必须写“未执行验证，待用户真机验证”。

## 2. 文件与当前 Git 状态（本次重新核实）

实施工作区：`D:/.codex/worktrees/agent-stdio-runtime/xiaoqi_app`。

正式 main 发布目录：`C:/Users/20833/Desktop/xiaoqi_app`。

- 工作区 HEAD：`82a81a3eb76594e06314059979f2b1040cf4e1b1`。
- 正式 main HEAD：`67e29ef1777dc4a8c915b02be1acdf95d3c0c6b6`，本次检查工作区干净。
- 两个 HEAD 是对应的 cherry-pick 提交，不能因哈希不同就判定内容缺失；需要比较实际 diff。
- 实施工作区有下面 6 个未提交修改，必须保留，禁止 reset/覆盖/重新从零实现。

共同前缀：`xiaoqi_harness/genkit_server/`

1. `lib/src/agent_runtime.dart`
2. `lib/src/plugin_commands.dart`
3. `lib/src/tool_execution.dart`
4. `test/plugin_agent_runtime_test.dart`
5. `test/plugin_commands_test.dart`
6. `test/support/plugin_agent_runtime_fixture.dart`

本交接文档是另外新增的文档文件，不属于上述六个实现文件。未为交接提交代码或启动发布。

必须先读：

- 项目 `AGENTS.md` 和 `.agents/skills/developing-genkit-dart/SKILL.md`。
- `docs/architecture/2026-10-26-agent-tool-permissions-audit.md`：P01–P14 范围与验收的原始依据。
- `docs/plans/2026-10-26-agent-tools-implementation.md`：实施流水账。
- `docs/architecture/evidence/`：各次验收和发布证据。

注意：实施流水账和 `2026-10-29-remaining-plugin-evidence.md` 含历史“待完成”记录，部分已被后续代码/测试/发布覆盖。它们不是当前剩余项的机械清单。先去重、核对实际证据，不重做已完成路径，也不忽略真正缺口。

## 3. 已完成的主要修复与证据层次

以下是已完成的子项，不代表所属 P 编号已经整体关闭。

| 范围 | 已实现并有验证的内容 |
| --- | --- |
| P01–P04 | 动作级 MCP 授权、具体参数和连接绑定、提交前复查；只读读取配置；技能与通用代码共存；意图推荐与能力发现分离；任务范围/revision 变化及撤回处理；临时网络授权与原请求恢复。 |
| P05 | 大型 MCP 分页/检索/按需调用、目录通知与刷新、调用前 schema 复查；121 工具目录和实际 Genkit 调用/刷新场景通过。 |
| P06 | XLSX、DOCX、PDF、PNG 的真实 Docker 多步复用；同名文件版本与跨任务隔离验证。 |
| P07 | 隔离 stdio MCP 安装、启动、发现、调用、结束；MCP 活跃会话不再被普通脚本两分钟时限误杀；取消与清理；原租约、原进程、原 RPC、结果与文件恢复，单次效果和单次计数的实际重启门禁。 |
| P08 | 通用 Shell 与已安装脚本、字面 argv、工作目录、环境、MCP 文件接力、后台子进程清理。 |
| P09–P10 | 组件独立可用性、健康组件继续执行；npm/Python 安装与组合构建、离线运行、执行位和旧包任务副本兼容；不修改不可变原归档；依赖安装结果恢复。 |
| P11 commands/agents | Markdown 命令发现、源版本绑定、真实子 Agent 会话、窄文件工具、审批恢复、嵌套权限、技能预加载、脚本联网链路。 |
| P11 hooks | 根 command Hook 基础、工具前/后/失败事件、输入与输出处理、源绑定、原生结果先落盘再执行 post-hook；只读子 Agent 的临时 Hook 计算不导出文件。 |
| P12 | 去掉计划次数对工具补读的硬阻断；失败/恢复累计计数；任务累计模型调用预算，并与实际 provider 请求数比对；恢复不能重置或重复扣预算。 |
| P13 | 执行身份、原授权关联、未知结果保护、安全读取恢复、产物保全和资源清理；已完成多个真实 runner/API 重启场景，不等于所有入口生命周期总验收完成。 |
| P14 | 已多次通过 CI、真实容器门禁、标准 ECS 部署、健康/数据/版本/恢复点检查；已有目标 ECS 代表任务资源测量。客户端真机仍未验证。 |

补充已完成的实际阻断修复：

- 官方 Python 时间 MCP `mcp-server-time@2025.8.4` 的 PyPI 安装、uvx/uv tool run 常见声明映射、stdio 调用、UTC→上海时区转换及清理已通过。并非完整 uv CLI 兼容承诺。
- 安装用私有根 `dependencies.zip` 单文件上限 20 MiB；普通产物单文件仍 10 MiB，总输出 20 MiB，展开依赖 40 MiB。即时/重启恢复/API/runner 保持相同规则，未全局放大限制。
- 目标 ECS 代表任务 MCP 与 CPU/文件执行重叠测量已有 24 个采样，最低可用内存约 1.01 GiB；不能代称任意并发压力测试。
- 已安装源清单检查为 14 个版本/10 条记录、零 active，只证明清单情况，不证明用户有某个正在启用的真实插件已成功执行。

## 4. 发布状态：必须区分三个批次

### A. 最后有完整成功证据的部署

- main：`eeb173c7c45e86743c5c50117cbb89c16ff451c3`。
- 发布：`20261030-073514-eeb173c`。
- CI：`40974111602`，job `123797795496`。
- CI 通过：467 Dart、93 runner、30 部署 Python、2 bridge、2 沙箱镜像检查，真实 stdio/重启门禁、镜像导出导入往返。
- 目标机完成探针、暂停写入、备份、激活、健康与数据验证、恢复流量、清理；`DEPLOY_OK`，唯一 `latest-good` 恢复点。
- 产品 `2026-10-27-agent-tools-2`，API contract `24`。
- 证据：`docs/architecture/evidence/2026-10-30-hooks-python-mcp-release.json`。
- 本次重新读取的部署日志：`C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/deploy/20261030-073514-eeb173c.log`，包含 `PUBLIC_RELEASE_VERIFIED` 与 `DEPLOY_OK`。
- 结论：此批 server deployed and verified；这不代替 11 月 1 日的线上实时健康检查。

### B. 最新已提交批次：CI 已成功，部署结果待核实

- main：`67e29ef1777dc4a8c915b02be1acdf95d3c0c6b6`。
- CI：`40977584323`，job `123809329180`。
- **本次交接重新查询：所有步骤 completed/success，包括构建测试、无付费服务 stdio 验收、导出与上传。**
- 内容：Hook command+args 无 Shell 直接调用、隔离目录占位符、UTF-8 Python stdin、根 once 正确语义；完整只读委派 Agent + Hook 的真实 Docker 验收。
- 历史部署进程 ID `27388` 现在返回 Unknown process id；临时日志 `%TEMP%/xiaoqi-hook-exec-delegated-deploy.log` 已不存在；本机持久部署日志中未找到此批成功记录。
- **不能据此推断它已部署，也不能推断远程作业未运行。新窗口先只读查询远程作业/当前 revision/健康，再决定是取回结果、等待还是重新部署，禁止重复启动远程激活。**
- CI 链接：https://github.com/Yseven004/xiaoqi_app/actions/runs/40977584323

### C. 当前未提交批次：context: fork 命令

仅工作区的上述 6 文件，本地定向验证通过，未提交、未进入 CI、未部署。

## 5. context: fork 实现进度与接续点

已经实现：

- PluginCommand profileVersion 1→2；解析 `context: fork`、`agent`，默认 general-purpose；background 字段校验为 bool，当前非交互/SDK 调用等待子结果，不引入后台调度器。
- 同一不可变安装源重新索引，支持旧无插件 manifest 的根目录命令；按 source_path/root 保留原命令 ID，避免旧显式选择失效。
- `run_plugin_command` 的 fork 分支复用原 `delegateAgent`，带入渲染参数后的独立任务；默认 Agent、Explore/Plan 只读模式、同插件同固定版本 custom Agent。
- 复用原审批、取消、恢复、嵌套权限、深度、预算、私有 PluginAgentSessions；子会话不应继承父聊天历史。
- 私有 `completed_plugin_commands` 与 loaded 状态分开；只有真实子任务成功才完成，拒绝/只读失败不伪称交付。
- 自定义 Agent 源和命令源共同绑定会话指纹，执行前复查；不改变公开 API contract。

已有定向测试：6 项通过（1 解析 + 5 实际 SDK）：默认写入、Explore 拒绝写入、同版本 custom Agent、审批后恢复只执行一次、拒绝后零执行。静态分析通过。审批前外部效果为零，拒绝和失败未标记完成。

明确尚未完成：

1. 添加旧安装重索引回归：已有健康命令保留 ID、原不支持 fork 的兄弟组件恢复、空 warnings、无 root manifest。
2. 重跑完整 `plugin_commands_test.dart` 和 `capability_import_test.dart`。早前一条测试预期仍把 fork 当不支持，已修改预期，但之后只重跑了 fork 定向集，完整集待重跑。
3. 跑 `capability_runtime_test.dart --name text-only-plugin-command` 的五类普通命令回归；该文件才是普通命令集，不存在 plugin_command_runtime_test.dart。
4. 跑完整 `plugin_agent_runtime_test.dart`，覆盖共享 delegateAgent 修改对普通 Agent、嵌套、预加载、审批恢复的影响。
5. 检查并补必要证据：父历史不泄漏、未知 custom Agent、审批期间撤权/源变化；不要写与实现完全镜像的无意义测试。
6. 将 fork 命令加入 `bin/support/stdio_agent_gate.dart` 真实 Docker 组合门禁，再由 CI 跑真实容器；本机没有 Docker/WSL，不安装新设备或用 mock 冒称 Docker。
7. 文档、提交、main 同步、完整 CI 与标准部署。

真实 gate 建议接续方式（未编码）：在现有 mixed + rootHooks + readOnlyDelegate 场景中增加 `commands/fork-read.md`，context fork 指向已有 readonly-verifier；直接 Agent 与 fork 各读一次。第二次 command search/run 必须按 tool arguments 区分，不能仅按工具名 called() 或猜 alias。预期代码执行 9 次（MCP 启动、Shell、原命令脚本、2 Bash Hooks、4 Read Hooks），Hook 成功 6 次；产物仍精确 4 个，不可变 SKILL 字节不变；custom Agent 完成 map 仍 1，fork command 完成 1，私有 child sessions 为 2。以实际协议核验这些预期，不为了绿灯盲改数字。

## 6. 剩余总计划：不只是 fork 这一项

按顺序推进；每项先确认已有证据，避免拿历史待办重复开发。

| 顺序 | 剩余工作 | 完成条件 |
| --- | --- | --- |
| 1 | 核实 main 67e29ef 的远程发布终态 | 找到精确 revision 的远程结果；如未部署且无活跃作业，走标准发布；健康/数据/版本/恢复点/清理都有证据。 |
| 2 | 收尾 context: fork 未提交实现 | 上述完整回归、真实 Docker、提交、CI、部署通过；拒绝/未知/失败不得记为完成。 |
| 3 | P11 必要协议缺口 | 动态命令、技能作用域 Hook、必要生命周期/异步行为、Agent 宿主字段、apps/extensions 的目标协议逐项绑定代表样本实施和验证；不能仅删除“不支持”提示。 |
| 4 | P09/P10 现有宿主与真实样本适配 | 逐样本确认依赖、资源、构建、脚本及健康组件；缺依赖可定位/恢复；必要 apps/extensions 若涉及新 UI，先走已要求的设计确认，不自行造界面。 |
| 5 | P01–P08、P12–P13 跨入口总验收 | 普通工具/技能脚本/Shell/MCP/command/Agent/Hook 权限、源版本、联网、撤权、取消、预算、错误恢复和清理证据齐全；仅补真实缺口，不重写已通过的 121 工具/二进制/重启实现。 |
| 6 | P14 最终收尾 | 对照 P01–P14 逐条关闭，整理准确的当前矩阵；剩余生产修改走单版本发布；客户端验证单独列出；交付最终验收报告。 |

P11 当前并未全面适配：动态 `!` 命令注入、command frontmatter hooks/permissionMode/skills/mcpServers、非 inherit model 等仍有拒绝分支；Agent 的 memory/isolation/background 等宿主字段需要按实际目标核验。根 Hook 已完成，不要受旧文档误导从头重做；但目前基础事件不能冒充所有 Hook 生命周期。也不应把上游所有 33 类事件和未来字段都无条件扩入范围：以原计划登记问题和选定真实插件的必要协议为准，有明确依赖/账号/产品阻碍就保留开放并说明，不能伪关闭。

跨入口总验收还需重点核实：连接健康变化后的发现刷新；共享网络下单调用结束与显式撤权的区别；资源读取入口/容量；旧无绑定文件恢复；并发/失败/恢复预算；API 重启前后待返回 RPC 证据是否覆盖所有承诺。部分项目已有后续真实门禁，先用新证据更新旧表。没有证据的标“待验证”，不要凭静态代码直接报已验证有效。

## 7. 最后验收标准

每个 P 项和代表样本分开记录：代码实现、自动化/静态检查、真实容器/目标平台、服务部署、真实效果、客户端/真机。任何一层不能冒充另一层。

1. 原审计 P01–P14 的每个验收条件有对应实现与证据；必要已登记问题全部修复，未验证/外部阻碍明确保留，不用“部分支持”冒充完成。
2. 代表真实技能/插件完成安装→发现→授权→执行→产物复用/交付→结束；记录源版本和许可证。包含组合调用，不仅 parser 或 mock 单测。
3. 正常任务内已授权操作不再被过粗开关、重复审批或计划次数误拦；只读不会变成持久写入；敏感动作准确遵守真实用户授权。
4. 拒绝、撤回、禁用、源更新、任务切换、取消及时生效；跨任务/租户/路径/版本访问和凭据泄露被拒绝；临时网络不跨调用泄漏，不误断其他正常任务。
5. 失败/超时/断连/runner 或 API 重启后，能收回原结果和产物；结果未知的副作用不盲重发；单次效果、单次计数、无进程/容器泄漏。不可恢复时准确报告未知，不伪成功。
6. 预算在父子 Agent、Hook、MCP、脚本、并发、失败和恢复间正确累计，现有服务器资源可承受代表任务，不靠无上限放开。
7. 相关自动化、静态检查、真实 Docker gate、镜像导入导出往返通过；失败必须修复，不删断言或降低验收掩盖问题。
8. clean main 与 origin/main 精确一致；用该 commit 的 CI artifact，经 `xiaoqi_harness/deploy/deploy_current.ps1 -VerificationProfile non-image` 发布；服务器不现场编译。激活前后健康/数据/公开版本/API contract 匹配，保留一个非运行恢复点并清理旧产物。失败自动回滚并复验健康。
9. 客户端与服务器为一个当前版本；无 API/Flutter 变化不重复重建 APK。真机由用户验证，未完成则独立写明，不能宣布“全部真实效果验收通过”。
10. 不调用欠费生图服务，不增加通用电脑/手机控制和采购要求；这些不阻塞当前确认范围的工程交付。

## 8. 运行与工具注意事项

- Dart：`C:/Users/20833/develop/flutter-3.47.5/flutter/bin/cache/dart-sdk/bin/dart.exe`。
- Windows worker 测试设 `XIAOQI_TEST_PYTHON=C:/Users/20833/AppData/Local/Python/pythoncore-3.14-64/python.exe`，Dart 测试串行，避免 SQLite DLL 锁；测试期间不改其代码。
- CI/远端可以真实 Docker；本机不可用不应安装或购买额外环境。
- 发布脚本、授权和安全约束以当前 AGENTS.md 为准。若阿里云 OAuth 过期，由 agent 启动 `aliyun configure --mode OAuth --profile xiaoqi-remote-deploy` 让用户在浏览器授权，绝不索取密钥。
- 不把观察超时当部署失败；远端作业独立运行，先查终态。旧会话 ID 不保证跨窗口可用。
- 原生工具测试、构建日志临时文件可能已清理，缺文件不能冒称检查过；优先持久证据和 CI。
- `C:/Users/20833/Desktop/xiaoqi_app/.codex-artifacts/client-current/app-release.apk` 是此前 APK 交付路径；新窗口如要交付先核对文件和 manifest。此前产品/API 为 2026-10-27-agent-tools-2/24，客户端未真机验收。
- 当前技能指引不授权对外发消息，不自行新开用户聊天或启用多代理；工具与并行权限以新窗口当前系统规则为准。
- 进度只报真实新增成果、剩余项和阻碍，不报无依据百分比或反复“快好了”；避免每个极小修改都重复完整部署，用可审查、连贯批次收尾。
