# 技能 / 插件真实运行验收

日期：2026-10-16。产品发布标识：`2026-10-15-extensions-1`；API 契约：`2`。

## 范围与实际状态

已实现公开 GitHub 仓库 / 子目录检查、候选选择、原子安装、启停、卸载、手动更新、多选对话接入。保留原有自建技能数据；市场示例不再默认安装，也不再伪装成已上架可用内容。

MCP（含插件内 MCP）、OAuth、hooks、commands、agents、客户端专有组件都不执行。“我创建的”和个人作者作品页保持空状态。本轮沿用已确认市场/详情页，不新增视觉方向。

| 验收层 | 证据与结论 |
| --- | --- |
| 代码 / 静态检查 | 服务端 `dart analyze` 通过；Flutter 相关目录与首页/市场页静态检查通过 |
| 自动化 | 服务端 61 项通过；客户端市场、多选、旧数据兼容、网络模式共 9 项通过 |
| 服务部署 | `20261016-091554-5221cd0` 已部署；健康、共享版本、持久化数据检查通过；保留一个 `latest-good` 恢复点 |
| 真实调用 | 已通过：导入 / 安装 API、两种真实仓库内容、三种代码运行时与两类锁定依赖 |
| 同状态视觉对比 | 未执行；沿用既有设计不等于本轮已通过视觉验收 |
| 客户端真机 | 未执行验证，待用户真机验证；必须使用契约 2 的新客户端 |

## 实现闭环

1. 检查只读取文件。通过匿名 Git smart HTTP 解析引用，固定 SHA 后从 GitHub codeload 获取包；不执行仓库安装脚本，不需要 GitHub token。采用该方式是因为实测 GitHub REST 匿名 API 命中了共享出口限流。
2. 插件拆为技能组件。兼容项使用同一个 Skills middleware；不支持的组件列出原因，不加载 MCP。无法静态确定的行为不承诺可用。
3. 安装记录存在 SQLite，内容包不可变。依赖准备完成才提交安装记录；重复安装幂等，失败不激活，更新失败保留旧版。更新保留启停状态；卸载后重装可重新启用。
4. 客户端只传 ID / 版本 / 可选组件 ID。服务端核对账号、安装状态与版本，只准备当次选中的内容；内部唯一别名隔离重名技能。运行中的任务固定版本，读取/执行前重新核对停用和卸载。
5. Genkit 原生 Agent 管理工具循环。资源读取、脚本调用和失败均记录任务及组件版本；不接受客户端传任意脚本或路径替代安装包。脚本失败保留错误末尾的真实原因；不会仅凭模型最终文本宣称脚本成功。

## 兼容边界（不是“任何 GitHub 扩展都能跑”）

- 支持有合法 YAML 头的 `SKILL.md`；标准 Agent Plugin 1.0、Codex/Claude 插件中的技能目录。MCP 引用、已声明的专有工具、自定义系统构建会被阻止；保守静态检查可能拒绝仅在说明中提到 MCP 的技能。
- Python / JavaScript / TypeScript 脚本使用现有非 root Docker 沙箱，默认无外网，120 秒执行上限。每次导入脚本请求外网均须确认；下一次脚本不能继承上一次的联网授权。授权提示包含可能访问或修改外部数据；不会自动重试未知副作用操作。
- 依赖只接受明确的 `requirements.txt` / `package.json` 声明。pip 只接受 wheel，记录版本与 SHA256；npm 使用官方 registry，锁定完整性哈希，禁用生命周期脚本，拒绝要求安装脚本的依赖。不会让模型猜安装命令。
- 安装时可用 wheel 和环境依赖准备成功，不等于技能的所有任务效果都已验证。没有声明的第三方库、浏览器、系统软件、外部账号、动态导入和运行时工具要求仍可能导致任务失败。页面明确区分格式检查、安装成功和真实执行；不宣传任意仓库兼容。
- 包限制：下载 20 MB，最多 3000 个文件、单文件 10 MB、解压总量 50 MB；拒绝越界路径、链接、特殊文件、加密项、重复路径和不一致 ZIP 文件名。依赖展开最多 40 MB、依赖 ZIP 最多 10 MB。本次最多 16 个扩展、32 个技能组件。

## API / 数据

`GET /health` 返回发布号和契约。正常鉴权 API 要求 `x-xiaoqi-contract: 2`；客户端先检查健康接口中的契约及发布号，不匹配时阻断并提示重建客户端/重新部署服务端。

- `POST /v1/capabilities/imports`：`url`，返回异步工作 ID。
- `GET /v1/capabilities/import-jobs/{id}` 与 `POST .../{id}/cancel`：查询与取消；账号隔离。
- `GET /v1/capabilities/imports/{id}`：检查详情，检查记录 24 小时有效。
- `POST /v1/capabilities/install`：`inspection_id`、`candidate_id`；更新时加 `update_id`、`expected_revision`。
- 原能力列表 / 详情 / visibility / delete 接口继续用于查询、启停、显示和卸载；导入的包不能通过普通同步接口篡改。

对话 `selected_capabilities` 为引用数组，每项包含 `id`、`version_id`，可选 `component_id`。任务内不能中途改绑版本。客户端缓存服务端结果，不在本地切换“安装”标记。

## 真实样本与来源

仅在临时验收账号/目录使用，不写入用户数据，不将这些仓库加入精选市场。

| 样本 | 固定 commit | 许可证与验证范围 |
| --- | --- | --- |
| [Anthropic brand-guidelines](https://github.com/anthropics/skills/tree/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/brand-guidelines) | `dbd4588f9e1033efb41dad4bef2f7947c8993d44` | Apache-2.0；独立文本技能，读取并核对颜色值 |
| [Claude frontend-design 插件](https://github.com/anthropics/claude-plugins-official/tree/8f814f49002ff824e8a9ba43cf96112dc7f5948d/plugins/frontend-design) | `8f814f49002ff824e8a9ba43cf96112dc7f5948d` | 技能内 LICENSE.txt 为 Apache-2.0；验证插件技能加载，不代表 Claude 专有功能可用 |
| [Anthropic webapp-testing](https://github.com/anthropics/skills/tree/dbd4588f9e1033efb41dad4bef2f7947c8993d44/skills/webapp-testing) | `dbd4588f9e1033efb41dad4bef2f7947c8993d44` | Apache-2.0；仅验证已安装 `with_server.py` 的本地服务生命周期，不声称浏览器自动化可用 |

最初曾用 PDF 技能的标准库脚本验证执行链路；核对 LICENSE.txt 后发现其为自定义限制条款，后续可重复验收改用上表 Apache-2.0 样本，不收录/分发该 PDF 包。

依赖样本：PyPI `packaging==24.2`、npm `is-number==7.0.0`，准备后断网导入使用；另验证 TypeScript 数值结果。混合 MCP 插件、多技能、同名、越权、取消、失败更新、重启与危险包使用可控自动化 fixtures，不连接真实 MCP。

技术参考：[Genkit Dart 工具调用](https://genkit.dev/docs/dart/tool-calling/)、[Genkit 1.0.0](https://pub.dev/packages/genkit/versions/1.0.0)、[Agent Skills](https://agentskills.io/specification)、[Agent Plugins 1.0](https://github.com/agentplugins/agent-plugins-spec/blob/main/spec/1.0.0.md)。使用项目现有 Genkit 1.0.0 和实验性 Agent API；没有添加自写工具循环或第二个插件执行引擎。

## 重复验收与部署

本地：服务端执行 `dart analyze`、`dart test`；Windows 测试须设置可运行的 `XIAOQI_TEST_PYTHON`，不能使用 WindowsApps 占位程序。客户端执行上述三个测试文件并分析相关目录。

真实验收入口：`xiaoqi_harness/genkit_server/bin/verify_extension_runtime.dart`，通过 Genkit CLI 1.44.1 的 `flow:run extensionRoundTrip '""' --non-interactive -- dart run bin/verify_extension_runtime.dart` 收集 trace。它使用临时 SQLite 和模拟设备身份，调用真正的导入/安装 HTTP handler，再通过同一运行时调用模型及远程沙箱。需要现有模型环境与 sandbox runner，不在文件或聊天中复制凭证。

最终执行日期 2026-10-16，Genkit trace `9cf91463e05cbfad69ba69266c163625`：27 个 spans，243448 ms，flow 成功；含 3 次 `use_skill` 与 2 次 `execute_skill_script`。真实导入与安装：brand-guidelines 独立技能、frontend-design 技能型插件、webapp-testing 脚本技能。前两个分别从其固定版本加载说明；脚本 `with_server.py` 先返回帮助，再启动本地 HTTP 服务、验证状态 200 并清理服务。Python 输出 `PYTHON_DEP=24.2`，npm 输出 `NPM_DEP=true`，TypeScript 输出 `TS_RESULT=42`。模型第一次技能名未匹配后由 middleware 恢复并成功加载；脚本参数第一次错误，依据保留的实际错误信息修正后成功。最终 trace 是修正后的通过轮次。

ECS 验证容器来自 `extension-verification.Dockerfile`，是一次性验收工具，不替换生产容器、不挂载用户数据。构建上下文需要 Dockerfile 与验证 Dart 文件；基础镜像为服务端 Dockerfile 的 build 阶段。CLI 退出依赖 `procps`，不能将缺少 `ps` 的清理错误误认为业务调用失败。

服务端变更经 `xiaoqi_harness/deploy/deploy_current.ps1` 上传和部署，脚本检查共享发布标识、健康及数据；失败自动回滚。最终部署号 `20261016-091554-5221cd0`，公网 health 返回 200，产品发布号与契约匹配，数据检查通过；保留当前版本与一个不运行的 `latest-good` 恢复点。验收完成后清理本轮临时容器、镜像及完整调试 trace，只保留本节脱敏摘要。

## 用户真机验收

1. 重建新客户端，确认旧契约被清晰拦截，新客户端能进入市场。
2. 导入上表文本技能，检查、安装，在对话选择后核对真实 `use_skill` 记录。
3. 导入技能型插件；尝试多选、停用、卸载、更新、取消安装与断网重试，确认页面与服务端一致。
4. 确认 MCP、“我创建的”、作者作品保持空状态；精选预览不能假装已安装。
5. 核对手机/平板布局、静态加载占位、错误文案、返回与退出；这一步尚未执行。
