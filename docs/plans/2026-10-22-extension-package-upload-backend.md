# 扩展包上传与连接表单 · 后端补齐

## 用户授权与范围

2026-10-22 用户要求先暂停 Flutter UI 改造，补齐前述后端缺口。Flutter 页面保持当前版本；仅同步必要的客户端 API 封装与发布/契约标识。

本轮补齐两处已确认原型依赖：

1. 本地插件/技能压缩包与 SKILL.md 的服务端检查、候选选择、真实安装、取消、失败恢复。复用 GitHub 导入的兼容性判定、依赖准备、租户隔离、不可变制品与安装任务。
2. MCP 连接表单在保存前测试当前地址与令牌；不为了测试暗中保存连接，不修改已有连接或保存临时令牌。

不新增市场发布、评分、付费、目录后台或新的第三方运行权限。Flutter UI 仍暂停。

## API 与实现取舍

- 扩展现有 `POST /v1/capabilities/imports`：GitHub 来源继续提交 `url`；本地来源提交 `file_name`、`archive_base64`，两种来源互斥。检查结果继续进入现有 import-job、inspection 与 install 接口，不重复建设任务系统。
- 上传格式为 `.zip`、`.skill`（ZIP）、`.tar.gz`、`.tgz` 和单个 `.md`（映射为 SKILL.md）。使用现有 20 MiB 压缩包、50 MiB 展开内容、单文件 10 MiB、3000 文件限制，而非照抄参考产品的 25/100 MB。
- ZIP 保留有界解压、CRC 校验、重复路径、加密/链接/特殊文件拒绝；TAR/GZip 在解压和解码阶段限制体积并核对条目类型、路径、重复项、校验和及实际长度。不向主机文件树直接解包，不执行上传代码。
- 上传包记录 `origin: upload` 与文件名、原包 SHA-256、内容摘要，不能伪称 GitHub 来源。安装来源与现有版本必须保持明确；失败或取消时保留原安装，并清理本轮临时制品。
- 上传得到的已检查制品与 GitHub 制品具有相同服务端管理边界，不能通过本地同步接口绕过检查覆盖。
- 新增 `POST /v1/mcp/connection-tests`，临时初始化并读取工具目录，复用公开 HTTPS / 私网地址检查，结束关闭连接；不持久化 URL、令牌或工具清单。原已保存连接测试接口继续用于已保存记录。
- 同步更新客户端封装和共享 release/API contract；本任务只维护一份当前契约，不增加旧客户端兼容分支。

## 参考研究

检索日期 2026-10-22。只借鉴现有项目与原始文档，不复制外部业务流程：

- [archive 4.3.0 文档](https://pub.dev/packages/archive/versions/4.3.0) 与 [原始仓库](https://github.com/brendan-duncan/archive)：现有固定服务端依赖，支持 ZIP / TAR / GZip；MIT。源码核对了 TarDecoder 的校验、PAX/GNU 名称与 TarFile 类型标记；库解析不等于应用的安全解包策略，仍需有界输入和逐条路径/类型检查。
- [MCP 2025-11-25 安全最佳实践](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices)：临时测试继承现有服务的远程端点与凭据边界，不开放内网访问或凭据透传。

## 验收、部署与回滚

服务测试覆盖：有效格式、插件/多技能发现、安装与重复安装、上传来源、租户隔离、格式错误、超限/炸弹、路径穿越、链接/特殊文件、CRC/TAR 校验、取消与原版本保留。MCP 临时测试覆盖参数校验、私网拒绝、临时令牌、无存储副作用与连接关闭。

必要 API/契约检查通过后，按 AGENTS.md 将同一发布提交到 clean main 并正常推送，运行 `xiaoqi_harness/deploy/deploy_current.ps1`，使用该精确提交的 CI 制品。激活失败由脚本自动回滚；部署后分别报告构建、健康、版本、数据与清理结果。保留现有密钥、环境与持久数据，仅一份非运行应急恢复点。

## 本地检查与发布标识

- 服务端 `dart analyze`：通过，无问题。
- 服务端完整回归：180 项通过。Windows 使用 `XIAOQI_TEST_PYTHON` 指向本机真实 Python，避免 Microsoft Store 占位程序影响既有代码执行测试。
- 客户端上传契约与能力选择测试：9 项通过。
- 共享发布标识：`2026-10-22-extension-upload-1`，API contract `18`。部署后 contract 17 客户端需要重新构建，不增加旧契约兼容分支。
- 运行部署结果写入仓库忽略的 `.codex-artifacts/extension-upload-backend/deployment-summary.md`；本记录只确认本地检查，不预先声称已部署。

本窗口没有实现或验证 Flutter 页面；用户已要求另开前端任务并行执行，页面和真机验收在该任务单独记录。
