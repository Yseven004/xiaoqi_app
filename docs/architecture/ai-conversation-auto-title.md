# 首页 AI 对话自动标题

## 已确认范围

- 只为功能上线后新建的首页 AI 对话生成标题；不批量处理已有历史，也不处理书内对话面板。
- 首个完整 AI 回答成功保存后，在后台尝试生成一次；失败时保留首条用户消息标题。
- 使用该轮会话模型。仅发送首条用户消息和助手可见回答，不发送附件正文、工具数据或任务产物。
- 用户重命名优先；自动标题不改变会话排序时间，不增加加载态或页面。

## 开源参考

- [LibreChat](https://github.com/LibreChat-AI/LibreChat), v0.8.8（仓库 README 当前版本），MIT License。
- [自动标题配置与提示词结构](https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/shared_endpoint_settings)：按完整回复生成；读取对话主要语言；只返回简短标题。
- 本项目移植适合现有 Dart/OpenAI 兼容请求层的流程与提示词结构，不新增 LibreChat 运行时或第三方依赖。

## 实现决定

- 本地 `title_revision`：缺失值 `-1` 表示旧记录；`0` 表示新记录待尝试；`1` 表示已发起一次尝试；`2` 及以上表示标题已定稿或被手动修改。
- 标题请求开始与完成都在历史服务的串行写队列内校验。手动改名会推进修订号；较旧会话快照写入时保留较新的标题。
- 标题请求失败后保留原标题，不自动重试；请求最多等待 20 秒，不阻塞正常聊天。

## 验收记录

- [x] `flutter build apk --debug` 构建成功；目标文件 `dart analyze` 未报告错误，但因 9 条既有 warning/info 返回非零状态；`git diff --check` 通过。
- [ ] 标题状态序列化及并发改名测试未编写或执行。仓库要求先用 ARTEMIS 探索应用再编写测试；本环境没有 ARTEMIS MCP 工具，`uv run artemis doctor` 也因找不到 `artemis` 命令失败。
- [ ] 目标设备为 Android 平板 TB335FC。调试包已安装并能启动；首轮问答、历史列表、手动改名及失败回退留待用户真机验收。
