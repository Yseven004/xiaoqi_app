# 创建图像入口兼容链路修复

日期：2026-10-13（北京时间）

## 根因

“创建图像”入口本身不会自动生成图片。空输入发送时，客户端在回合 metadata 中传递了明确的 `current_turn_text: ""`，同时为历史消息保留了合成展示文案：

```text
我选择了“创建图像”，请结合当前对话继续。
```

服务端 `XiaoqiApi._runRemoteAgent` 原先无条件用最新用户消息正文覆盖 `current_turn_text`。因此合成文案覆盖了空字符串，`agent_runtime.dart` 的空输入保护没有机会生效，入口被误当成生图需求直接调用图片服务。

这属于客户端和服务端对同一个请求字段理解不一致，不是模型判断错误，也不是多个运行容器同时分流。

## 修复

- 显式存在的 `current_turn_text` 永远优先，包括空字符串。
- 服务端只保留最新版客户端的请求格式；不再识别旧客户端的占位文案。
- 增加 API 回归测试，覆盖最新版协议的显式空输入。

## 远端发布与清理

- ECS：香港实例 `i-j6cdji1nji415swaliji`。
- 新镜像：`sha256:04b92399b88ca17ffb4cf9e0ad383a3cff7ee7fdd6f4286ef47dd2ffd14bcabd`。
- 运行状态：`xiaoqi-single-server-app-1` 为 `running|healthy`；公网 `/health` 返回 HTTP 200。
- 部署前后 SQLite 与对象清单匹配：212 个文档、75 个对象文件。
- 旧 Genkit 标签、旧 sandbox-runner 回滚标签和未参与当前 Compose 的旧 stack 标签已清理；当前 app 只保留 `xiaoqi-genkit-server:local`。
- 开发阶段的历史回滚备份已清理；服务器 `/opt/xiaoqi-single-server/backups/` 当前为空，不参与运行。

## 验证边界

服务端 `dart analyze`、完整远端 Dart 测试和本地 25 项相关回归测试通过；公网健康检查通过。尚未在用户的 Android 客户端上重新点击“创建图像”做真机闭环，因此客户端视觉与真实 Ark 账单路径仍待设备复测。
