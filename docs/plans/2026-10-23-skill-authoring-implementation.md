# 已确认技能流程 · 实现记录

依据：[确认规格](../design/extension-market-v2/skill-authoring-confirmed-2026-10-23.md)。共享 release `2026-10-23-skill-authoring-1`，API contract `20`。状态：代码已接入；服务端检查通过，等待部署与客户端验收。

## 实现决策

- 复用 CapabilityDraft、CapabilityStore、已检查导入包和现有 A2UI 目录；不引入新 SDK 或独立插件引擎。内置技能创建助手由真实 manifest 与 SKILL.md 注册到现有创建入口，不注入虚假市场安装记录。
- 保留内部技能标识；中文名称、详细介绍、图标和有序图片存入 presentation。新草稿按账号隔离持久化，使用现有草稿 API 同步；新创作草稿不进入旧草稿清理队列。
- 复用 SQLite CloudStore 与已有不可变包存储。发布保存受版本检查保护的独立快照；私人编辑与已安装版本不随公开版本改变。发布和安装均验证真实账号、归属与版本，不信任客户端传入的作者字段。
- 图片采用本地原生解码和尺寸压缩；单图最多 512 KiB、图标 128 KiB、最多 6 张介绍图。上传原文件最多 10 MiB；不支持内容明确报错且保留草稿。SVG 图标仅允许无脚本、外链与嵌入位图的固定图形。限制同时由服务端执行。
- 导入检查沿用现有策略；导入到创作草稿只返回所选技能子树，不直接安装。创作技能沿用正式包 2 MiB 上限。导入别人的文件不构成取得对方已发布记录的编辑权限；安装的 market/github/upload 记录在服务端拒绝同步覆盖和作者发布。

## 外部参考与取舍

检索日期：2026-10-23。仅参考原始文档与成熟项目；没有复制第三方市场代码或替换已固定依赖。

| 来源 | 版本／更新依据与许可 | 借鉴与取舍 |
| --- | --- | --- |
| [Genkit Dart A2UI](https://genkit.dev/docs/dart/agents/a2ui/) | 当前文档；项目固定 genkit 1.0.0、genkit_a2ui 0.4.0 | 复用 actionToMessage、现有追问组件目录与会话；不另造生成式 UI 协议。 |
| [A2UI 官方仓库](https://github.com/a2ui-project/a2ui) | 2026-10-23 读取 main 说明，Apache-2.0；不升级依赖 | 参考声明式受限组件及客户端动作回传；不让模型生成任意可执行客户端界面。 |
| [Cline Marketplace](https://github.com/cline/marketplace) | 2026-10-23 读取 main 说明，Apache-2.0；未复用源码 | 借鉴目录资料与具体安装版本分离；小七使用既有单机服务和数据库，不增加 Git 托管目录发布链。 |
| [本地固定 Anthropic Skill Creator](../../third_party/anthropic-skill-creator/SOURCE.md) | commit `8a1541c4a3ffa5a20a5a91de0dcf3f0bab1d1ef4`，Apache-2.0；本次未更新 | 只保留既有渐进披露写作指导，新增小七自己的 A2UI 澄清、确认与草稿交接包装。上游页面本次抓取失败，未以搜索摘要替代本地固定来源。 |

## 视觉与资产

- 以两张已确认图为准：1048×1501 源图对应约 834×1194 平板目标；页面水平留白约 30dp，主图标约 108dp，普通正文 16sp，固定底部操作 52dp。
- 导入按钮只在原右上角改为黑底白字；没有新增导入区块。手机沿用窄屏缩排、可滚动文件区和底部操作，等待用户实机检查。
- 固定图形复用 assets/icons/extension_market/detail 的 Phosphor SVG，与既有资产清单和独立预览一致；不裁用整页 PNG 或报告示例，不新增默认技能、案例或市场数据。
- 用户自己上传的图标和介绍图是内容数据，与页面控件资产分开。预览与真实技能详情复用同一只读组件，编辑控件不出现在公开效果中。

## 检查与发布进度

- 服务端 `dart analyze lib test` 通过，全量 `dart test --reporter expanded` 185 项通过。Windows 测试使用已有 XIAOQI_TEST_PYTHON 覆盖项指向实际 Python 3.14，避开无输出的 WindowsApps 别名；没有为环境问题修改业务代码。
- 草稿本机写入串行执行；延迟返回的同步结果保留请求期间的新编辑，只更新同步版本。不同设备的内容冲突保留本机草稿，可另存为新草稿；同内容网络重试不重复报冲突。
- 新增服务端发布／安装隔离、公开快照、私有草稿与导入子树测试；新增客户端纯状态测试，客户端测试未运行。
- 按项目约定，未运行 Flutter analyze/test/build/run、设备动作或页面截图；未执行验证，待用户真机验证。生成图与 Dart 文本格式检查不作为视觉验收。
- 代码、服务器部署、数据与健康检查分别记录；当前还未部署。全部服务端检查通过后，按 deploy_current.ps1 的 main／CI artifact 流程发布。
