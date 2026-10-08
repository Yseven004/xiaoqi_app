# 技能创建续作：当前状态与开发入口

核对日期：2026-10-08。依据当前本地代码和已保存部署记录；本轮没有重新验证线上服务或执行真机测试。

> 后续用户已扩大范围：创建、使用、公开 GitHub 导入技能，并支持 Python、JavaScript、TypeScript 脚本；私有仓库和用户插件创建后置。下文“纯文本范围”保留为本轮最初核对依据，已由 [技能完整闭环方案](2026-10-08-skills-full-workflow.md) 中的用户确认范围替代。扩大范围不代表新 UI、隔离实现或验收已经完成。

## 当前结论

可以继续推进开发，但不能把已有聊天部署当成第四阶段验收完成。继续沿用架构规定的顺序：对话、本地持久化、多用户隔离、纯文本技能。可执行插件生成仍为后置项；是否扩大范围等待用户明确。

| 阶段 | 已有证据 | 尚缺证据或实现 |
|---|---|---|
| 对话 | 第一阶段部署记录记载 ECS、HTTPS、邮箱登录、平板 DSH 对话已验证 | 完整失败、中断验收不能由一次正常对话替代 |
| 本地保存 | CapabilityStore 已使用 SharedPreferences 保存技能与草稿；首页已有提交正式版本入口 | 重开、离线、保存失败及书籍/笔记/聊天/文件引用的完整验收未在本轮找到 |
| 多用户隔离 | Harness 工作目录按 tenant 与 task 哈希分隔 | 当前 Compose 的 app 为共享容器；不是架构要求的每用户独立容器与配额故障隔离。未找到双账号完整验收 |
| 技能创建 | 已有创建标签、SkillCreatorAdapter、draft_workspace、回复解析、草稿和正式保存代码 | 未证明在新架构下完成创建、试用、保存、重开、再次调用闭环 |

## 已发现的范围冲突

1. `lib/features/capabilities/data/skill_creator_adapter.dart` 仍指导生成 Python 和资源文件；新架构第四阶段仅允许纯文本 SKILL.md，不能直接沿用旧范围。
2. `lib/pages/home_page.dart` 的 `_saveSkillDraft` 和 `_requestSkillDraftRevision` 仍触发云同步；新架构以手机原件为准、跨设备同步暂缓。需追踪实际同步开关与调用效果后调整，不能仅凭调用名称认定发生上传。
3. `CapabilityStore` 使用设备级存储键；账号隔离策略及切换账号后的技能可见性需沿调用链核实，不能据此直接宣称已发生跨账号泄露。
4. 当前管理后台的 DSH 插件安装/配置，与普通用户在 App 创建可执行插件，是两个不同的功能，前者不能充当后者完成证据。

## 继续实施顺序

1. 核验第二阶段的本地持久化、失败反馈与现有导出机制，记录真实缺口。
2. 按已确认架构完成第三阶段的用户执行隔离；技术实现前重新检索锁定版本官方资料，具体配额与账号行为存在未决项时先确认。
3. 复用既有技能界面，对照冻结交互核实受影响状态；若需改变账号可见性、保存或加载行为，先完成 Product Design 确认。
4. 统一纯文本技能创建边界，接通生成、代表性试用、用户保存、重新打开、再次调用；验证路径、大小和账号权限。
5. 分别记录代码、静态/自动化检查、同状态视觉、目标平台、部署与实际有效性；不互相替代。

## 本轮交付边界

完成状态核对和续作清单，未修改业务实现、未部署。未执行验证，待用户真机验证。当前工作树还有管理后台与部署相关未提交改动，后续实施应保留这些改动。

## 依据

- `docs/architecture/2026-10-06-xiaoqi-single-server-harness-architecture.md` 第 0 节：已确认的四阶段顺序和纯文本技能范围。
- `docs/architecture/2026-10-08-stage1-deployment-and-legacy-cleanup.md`：第一阶段部署与真机证据。
- `lib/features/capabilities/data/capability_store.dart`、`skill_creator_adapter.dart`、`lib/pages/home_page.dart`：本地保存、创建提示及保存调用。
- `xiaoqi_harness/capabilities/harness_worker.py`、`worker.py` 与 `xiaoqi_harness/deploy/compose.yaml`：工作目录、草稿工具和容器布局。
