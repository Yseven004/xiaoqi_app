# 生成图片加载优化

## 范围与原因

用户于 2026-10-21 确认直接修复，并采用行业通用缓存方案。目标是减少已生成图片重新进入对话后的等待，以及图片生成完成后的展示等待；保留现有页面、图片原件、标注交互和远端 API。

历史追踪确认：`5a977704`（2026-10-09）已经引入组件内图片 Future 缓存，并在切换对话时清空。它不是本次标注改动引入的问题。预览直接等待完整产物下载，没有持久化图片缓存；`Image.memory` 默认按原图尺寸解码。

## 外部参考与取舍

以下于 2026-10-21 查阅，项目源码仅作为参考，没有复制其实现：

| 来源 | 版本 / 日期 | 许可证 | 借鉴与使用 |
| --- | --- | --- | --- |
| [Baseflow/flutter_cache_manager](https://github.com/Baseflow/flutter_cache_manager)、[包文档](https://pub.dev/packages/flutter_cache_manager)、[Config](https://pub.dev/documentation/flutter_cache_manager/latest/flutter_cache_manager/Config-class.html) | 已解析并锁定 3.4.5；包页面标记发布于查阅前 32 天 | MIT；已核对所安装包的 LICENSE | 直接依赖，用于文件持久化、元数据、过期与容量清理，避免自建磁盘缓存管理器 |
| [Flutter Image.memory](https://api.flutter.dev/flutter/widgets/Image/Image.memory.html)、[MemoryImage](https://api.flutter.dev/flutter/painting/MemoryImage-class.html) | 本机 Flutter 3.47.5 对应 API；文档于查阅日确认 | Flutter BSD-3-Clause | 使用 `cacheWidth` 限制聊天预览的解码尺寸，复用相同字节对象以复用框架解码缓存；原图查看和编辑仍使用原件 |

## 实现与边界

- 只给图片产物启用缓存，其他产物保持原下载行为。预览、图库、保存和预取共用下载入口。
- 使用进程内 32 MiB 编码字节缓存，按最近使用顺序淘汰；Flutter 自身管理解码图片缓存。
- 使用独立 `flutter_cache_manager` 命名空间，清理策略为 100 个文件、30 天未访问；这是文件数量策略，不是磁盘字节硬上限。缓存可由系统回收，不能作为用户数据的唯一保存位置。
- 缓存键是服务地址、登录 token、任务 ID 和产物 ID 的 SHA-256；磁盘键和元数据不保存 token。账号、登录会话或服务地址变化后不能命中旧身份的缓存。
- 产物 ID 对应不可变内容，因此命中缓存时读取本地文件，不进行 HTTP 重新验证；缓存缺失时仍先进行现有版本匹配校验，再鉴权下载。HTTP 层保留服务端 `private, no-store` 设置；此处保存的是用户已授权读取的应用私有内容，缓存不会变为公开资源。
- 相同图片的并发加载合并为一个请求；多图片并发时合并版本检查。失败不保留失败 Future，后续可以重试；磁盘不可用时仍显示网络下载结果；空响应不入缓存。
- 收到流式图片产物元数据时预取，在任务结果入库和页面渲染期间重叠下载；预取失败不阻断生成结果。
- 聊天预览按逻辑宽度乘设备像素比解码，不修改磁盘原件。首次下载、缓存被回收、登录 token 改变时仍需要网络；本次不改变模型实际生图耗时。

## 降级与回滚

磁盘缓存错误自动退回网络和内存；网络错误维持现有失败提示。需要回滚时撤销本次客户端缓存与预取调用即可；缓存数据可丢弃，历史消息与原始产物无迁移。没有修改服务端、API 契约或发布标识，因此不需要服务器部署。

## 验收

- 代码已接入；新增自动化覆盖内存复用、缓存管理器重建后的离线恢复、并发合并、账号/服务/任务隔离、失败重试、空数据、内存淘汰、系统删除缓存、磁盘写入失败、版本校验和退出登录。
- `flutter test --no-pub --reporter expanded test/task_artifact_image_cache_test.dart test/chat_annotations_test.dart test/ai_chat_process_test.dart`：31 项通过，其中新增缓存测试 13 项。
- `flutter analyze --no-pub --no-fatal-infos` 检查缓存服务、云端客户端、主页及新增测试：退出码 0，无错误或警告；主页原有 `use_null_aware_elements` 风格提示 1 条，未扩大本次修改范围。
- `git diff --check`：通过。
- 尚未执行真机延迟测量、视觉对比或目标平台验证，待用户客户端验证；不将请求数测试当作真机毫秒级提速证据。
