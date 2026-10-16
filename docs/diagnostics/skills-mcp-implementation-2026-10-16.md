# 通用技能与 MCP 修复记录（2026-10-16）

## 用户可见问题

- 已安装技能在聊天中提示“无法读取指定版本”：客户端把“本机是否缓存技能正文”误当成“指定版本是否存在”。
- `book-to-skill` 因仓库提及其他客户端/MCP，以及使用 `pyproject.toml`，被扩展导入器过度判为不支持。
- MCP 缺少连接管理、选择、调用确认与服务端传输流程。

## 本次改动

- 技能/插件选择携带精确的扩展 ID、版本 ID 与组件 ID；服务端从所属账号的不可变版本包读取正文，不依赖手机缓存。规则对所有技能/插件通用。
- 有可用组件但依赖不由安装器自动准备的技能，以“可安装并附依赖提示”处理；实际不可支持的组件仍拒绝。安装器保留这类组件的原始文件。
- 添加远程 HTTPS MCP 连接器管理与 Genkit Dart MCP 客户端；Bearer 凭据按账号加密保存。工具调用前在现有交互样式中展示工具名与参数，并要求用户确认。
- `book-to-skill` 在小栖中走附件分段阅读和可审阅技能草稿流程。当前 PDF、EPUB、DOCX、HTML、Markdown/TXT 可提取文本；扫描 PDF OCR 与仓库声明的任意 Python 依赖自动安装不在本版支持范围。
- `good-learning` 所需 XeLaTeX/CJK 字体加入沙箱镜像，并在部署激活前检查。
- 选择技能时按需开放已有生图工具，以支持明确要求图片的技能；不因工具可用而自动多生成图片。
- 客户端和服务端统一为 release `2026-10-16-skills-mcp-1`、API contract `3`。

## 验证状态

- 服务端 `dart analyze`：通过；全量 `dart test`：67 项通过。
- Flutter 定向静态检查：通过；扩展市场/选择用例：7 项通过。
- Flutter 全量 `flutter analyze`：退出码 0；显示 36 条既有 info 提示，涉及其他文件。
- APK 构建：已完成。Flutter 官方 Maven 源解决了镜像超时；构建时临时把生成的 Pub 路径映射到实际缓存目录以绕过 Windows 链接路径的 JNI CMake 问题，并关闭 Kotlin 增量编译。构建成功后已恢复这些临时生成文件。APK：`build/app/outputs/flutter-apk/app-release.apk`，SHA-256：`AC1588AB4FBD6A327E6387FC2191C1CCB1A9850F028EFEE12FB2F11A9C9BDD55`。
- 云端部署：已通过阿里云 ECS Cloud Assistant 完成并验证。目标实例 `i-j6cdji1nji415swaliji` 保持运行，部署版本为 `20261016-180004-b13b896`，健康检查返回 HTTP 200，`release_id=2026-10-16-skills-mcp-1`、`api_contract_version=3`；旧的 `latest-good` 回滚点和持久化数据仍在。
- 手机真机验证：待用户完成。

## MCP 支持边界与官方参考

- 当前接入远程 HTTPS MCP（Streamable HTTP）与 Bearer Token；未接入本机 stdio、其他客户端专属组件或浏览器 OAuth 登录。
- Genkit Dart 的 MCP 客户端参考：[genkit_mcp 官方包文档](https://pub.dev/packages/genkit_mcp)。
- GitHub 远程 MCP 地址与 Token 方式参考：[GitHub 官方 MCP 配置文档](https://docs.github.com/en/copilot/how-tos/copilot-in-your-ide/customize-copilot/extend-copilot-with-tools-and-context/set-up-the-github-mcp-server)。
- `book-to-skill` 的导入源固定为提交 [`a24e62f4d8caf2ee433f6e48d9073800f56f906e`](https://github.com/virgiliojr94/book-to-skill/tree/a24e62f4d8caf2ee433f6e48d9073800f56f906e)。
