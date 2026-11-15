# DeepSeek 聊天画布转写记录

## 验收依据

- 主要目标为用户提供的 DeepSeek 网页端录屏；录屏文件为 720×1152 像素。该数值描述视频画布，不等于 Flutter 逻辑像素。
- 补充状态依据：`deepseek-ai/chat-demo` 固定提交 `5d5dd754ebc1948e977ddb880a9eb5aa25f37b4c`，遵循 MIT，来源与声明见 [`third_party/deepseek-chat-demo`](../../third_party/deepseek-chat-demo/SOURCE.md)。
- 真机 DPR、安全区和同状态视觉差异需在目标手机上核对；代码接入本身不代表视觉验收通过。

## 页面对应

| DeepSeek 交互 | 小栖实现位置 | 适配说明 |
| --- | --- | --- |
| 用户提问气泡、助手 Markdown 回答 | `HomePage` 消息画布、`_assistantMarkdown` | 保留小栖消息树和批注/专有卡片语义；回答继续使用已有 Markdown 渲染器 |
| 思考标题、折叠时间线、步骤状态 | `_AgentProcessPanel` | 展示模型思考原文与服务端真实事件；不展示参数、原始返回或日志 |
| 流式回答、思考和来源更新 | 现有 Genkit Agent stream 与 `_handleAgentChunk` | 用户上滑时停止跟随；切换会话后后台消费并持久化原会话结果 |
| 来源胶囊、角标和来源弹层 | `_AgentSourcesCapsule`、`_AgentSourceListTile` | 生成与完成态使用同一来源快照，缺失时不补造 |
| 多问答选择、图片预览、公开快照 | `_shareReply`、`_ChatSharePreview` | 默认选中当前问答；长内容分页，Markdown 与来源进入同份快照 |
| 思考图标 | `assets/images/deepseek_think_outline_16.svg` | 按上游 `IconThinkOutline16` 路径独立交付 SVG，资产预览尺寸为原版 16×16 viewBox |

## 状态和服务接口

- 任务心跳每 10 秒续期；超过 60 秒未收到心跳时服务端请求暂停；恢复沿用原任务快照。
- 停止保留当前输出；切换会话不取消任务，完成后写回所属会话。断连恢复、事件序号去重和不可恢复提示沿用任务服务的既有状态边界。
- 分享快照只收录选中问答及其网页来源。创建、本人查询、会话批量撤销、单条撤销、旧链接关联、公开查看和删除前撤销使用契约 34。

## 验收状态

- 代码与接口按此记录实现。
- 已执行定向静态检查、相关服务检查和 Flutter 安装包编译后更新结果。
- 未执行真机交互和同尺寸截图对照；由用户在真机上验收后记录。
