# 部署可靠性与异机构建

已确认：先补牢部署流程，再将构建移出线上服务器，并实际验证。下方早期运行记录为迁移历史。

最新范围：用户要求收录已验证的部署改造到 main，直接从 main 构建，并取消本次市场创作编辑页、个人主页及相关创作发布功能。客户端与服务端均恢复现有功能边界，采用 `2026-10-22-main-deploy-1`，恢复原有 API contract 17；不删除已有私人记录或附件。四张本机设计参考图的删除被自动审批以“策略阻止”拦截，保留在本机且由 .gitignore 排除出提交。

## 方案

- 保留 deploy_current.ps1 为唯一部署入口。已审核改动正常提交、推送 main；入口校验工作区干净且 main 与 origin/main 一致，不暂存、提交、推送或生成构建分支。
- GitHub Actions Ubuntu runner 从 main 的精确提交执行服务端静态检查、测试、四个镜像构建及部署脚本测试；导出单平台 linux/amd64 成品、镜像 ID、源码及 SHA256 清单。过期产物只允许对相同 main 触发一次重建；切换前再次检查 main 未变化。
- 构建环境不接收服务器环境文件、业务数据或云凭据。GitHub 访问令牌只通过本机已有 Git credential helper 在内存使用；给 ECS 的仅为短期、单个产物下载链接。
- ECS 只下载、核对、加载镜像、执行现有合成运行时探针、备份、切换和验证；禁止现场 docker build，禁止 Compose 隐式构建。
- 部署前检查工具、磁盘、可用内存、inode、架构、当前健康和备份空间；全程持有部署锁。
- 远端任务独立于云助手连接执行，完整日志保存在权限 0600 的服务器文件，本机轮询有限的进度并保存完整副本。控制器丢线不终止部署、不删除仍在使用的包。
- 失败保留旧服务；切换后的失败自动恢复代码、镜像和数据并重新检查。最终公网 release/contract 与数据核对放在回滚点提交之前。
- 切换与数据核对期间 Caddy 只开放健康检查，其他请求暂时返回 503；核对后恢复流量，避免验证期间新写入被误判为数据损坏或被回滚覆盖。
- 成功后只保留当前服务和一个非运行恢复点；清理构建缓存、旧上传和无用项目镜像。日志有大小/保留数量上限。

## 验证

自动化覆盖缺字段的云助手结果、拒绝重复提交远程变更、预检失败、锁冲突、损坏发布包、异常包路径、成品镜像/源码校验、切换失败恢复和日志读取。实际用 Actions 构建后部署，核对公网健康、版本、数据清单、容器状态、备份和清理结果。失败演练在隔离目录与模拟 Docker 中进行，避免故意破坏生产数据。

## 参考与取舍（2026-10-22）

- Docker 官方 [GitHub Actions 传递成品镜像](https://docs.docker.com/build/ci/github-actions/share-image-jobs/)：参考 docker save/load + artifact 流程，未复制应用代码。
- GitHub 官方 [workflow artifacts](https://docs.github.com/en/actions/tutorials/store-and-share-data)：使用不可变构建产物与短期下载，不向 CI 提供线上密钥。
- Docker 官方 [image load](https://docs.docker.com/reference/cli/docker/image/load/)：使用压缩单平台镜像包，加载后再次核对 ID。
- actions/checkout v4 与 actions/upload-artifact v4（MIT）：使用官方 Action，工作流锁定 2026-10-22 查询到的提交 SHA。
- 暂不引入镜像仓库、长期机器或新的付费服务；复用现有 GitHub 仓库与 Actions。离线/认证失败时在切换前停止，旧服务继续运行。
- Docker 官方 [containerd image store](https://docs.docker.com/engine/storage/containerd/) 与 [Moby inspect 实现](https://github.com/moby/moby/blob/master/daemon/containerd/image_inspect.go)：首轮实际加载验证发现 classic/config ID 与 containerd/manifest ID 语义不同。构建机统一采用 containerd，并在上传前删除成品镜像、重新加载导出包、核对全部 ID；不放宽 ID 校验。

## 实际验证结果（2026-10-22，Asia/Shanghai）

- 首轮 [Actions 39771778478](https://github.com/Yseven004/xiaoqi_app/actions/runs/39771778478)：构建及测试通过。服务器加载后因 classic/config ID 与 containerd/manifest ID 不同而在切换前停止；原运行版本健康，未进入数据备份或切换阶段。完整错误日志成功分段取回。
- 最终 [Actions 39773488078](https://github.com/Yseven004/xiaoqi_app/actions/runs/39773488078)：匹配 containerd；13 项部署/包安全/恢复/数据测试、PowerShell 控制器与健康检查测试通过；Dart analyze 无问题，172 项 Dart 测试通过；runner 10 项、proxy 2 项 Python 测试通过。成品删除后重新导入、全部镜像 ID 核对通过。
- 成品来自 `dc2ad937c57e3251bdbf1bcbe435085c1f7f0076`，约 552MB。服务器只下载和加载成品，无 docker build 或 Dart 编译步骤。
- 生产部署 `20261022-194906-ff36a9d` 已完成：成品 SHA256、源码提交、平台、镜像 ID、五组真实模型/技能探针、数据库 quick_check、记录内容哈希及对象文件哈希均通过。
- 维护观察使用正确 contract 18：20:00:50 普通请求 503；维护期间 `/health` 200；20:01:04 无凭据请求恢复正常 401。部署日志记录写入保护窗口约 32 秒。观察仅发送读取请求，未提交登录、业务写入或邮件。
- Windows 本机 curl 的 Schannel TLS 握手仍失败；脚本自动通过 Cloud Assistant，用 Linux curl 对相同公网 HTTPS 地址正常校验证书与健康响应。未跳过 TLS 验证。公网返回 status=ok、product=2026-10-22-market-creation-1、contract=18。
- 独立复查：app 与 sandbox-runner 均 healthy，实际运行镜像 ID 与清单相同；数据备份清单 459 条记录、96 个对象文件；restore 仅 latest-good，四个项目镜像各只有 local/restore 标签；构建缓存 0，staging/incoming 均 0。磁盘约 25GB 可用，可用内存约 1.1GB，Swap 使用 0。
- GitHub 上仅保留当前 server-release 成品，失败轮成品已删除；构建日志保留 7 天。服务器日志权限 0600，最近七份；最终完整日志 11,411 字节，已取回本机 [部署日志](../../.codex-artifacts/deploy/20261022-194906-ff36a9d.log)。工作分支仍 main，暂存区保持未改动。

本机控制器还补测了空日志、恰好一个/两个分块、跨分块中文日志，均保持字节完整。这是本机日志读取逻辑，不改变 ECS 运行代码或 API。

边界：切换失败、恢复失败与中断快照恢复在隔离目录及模拟 Docker 中验证，未故意破坏生产服务；生产完成了正常发布、真实运行探针、写入保护观察、健康与数据核对。本次不包含 App 真机视觉验收。
