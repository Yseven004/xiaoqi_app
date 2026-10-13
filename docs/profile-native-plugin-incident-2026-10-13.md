# Profile 构建故障：根因证据与完整修复方案

日期：2026-10-13，Asia/Shanghai。

## 结论

已证实的直接根因是客户端原生插件生成清单不完整，导致插件未注册、原生依赖未打包。不是已经证实的“服务器全部宕机”，也没有证据表明 profile 模式本身不支持这些功能。

调查开始时 `.flutter-plugins-dependencies` 的 Android 列表只有 `photo_manager`，Android `GeneratedPluginRegistrant.java` 也仅注册该插件。安全存储、扫码、共享偏好、录音、JNI 等均遗漏。缓存中的对应包和 pubspec 实际存在。

本机旧 `build/app/outputs/flutter-apk/app-profile.apk` 的 arm64 库只有 libapp.so、libflutter.so、libpdfium.so、libvmservice_snapshot.so，没有 libdartjni.so。这与截图的 JNI 加载失败一致。此 APK 修改时间为 17:36:31；尚未对平板安装包做哈希比对，因此不把本机包与设备包认定为字节相同。

进一步追查发现一个时间上吻合、风险很高的变更：提交 `654a5d9`（2026-10-13 15:05）新增了 `android/settings.gradle.kts` 逻辑，在 Gradle 配置时直接用文本替换并覆盖 Flutter 生成的 `.flutter-plugins-dependencies`。它是故障前最近对插件加载管线做的改动，且不是 Flutter 官方生成流程。它可能导致插件路径解析或并发生成异常，因此列为首要嫌疑。

但不能把它说成已证实的唯一触发原因：调查时已无法取回出问题那一刻的插件元数据和 Flutter verbose 输出。对当前重新生成的完整清单，在内存里执行相同的反斜杠替换后，JSON 仍有效，Android 插件仍是 27 个。这证明替换文本本身不会直接删掉插件条目；真实影响须在出错状态下复现，或拿到那次构建日志才能定案。近期提交也把 photo_manager 改为本地 path 依赖，和“只留下本地插件”的异常形态相符，但单凭相符不能证明因果。

因此精确结论是：直接故障原因已证实为 profile APK 使用了缺少大部分平台插件注册与 JNI 库的构建状态；最可疑的引入路径是上述 Gradle 插件清单改写，加上它未被构建前检查发现；元数据为何在那次运行中最终只剩一个本地插件，仍待复现。不能归因于 profile 模式本身，也不能归因于服务器健康状态。

## 现场证据

1. 用户截图：安全存储 read 抛 MissingPluginException；侧栏报告 libdartjni.so 加载失败；扫码没有相机画面。
2. 设备：ADB 识别到唯一设备 TB335FC，serial 为 `adb-HA2FXQ2J-fWvoX7._adb-tls-connect._tcp`。启动现有应用后，17:55:41 日志复现 secure_storage/read、record/create、receive_sharing_intent/reset 的 MissingPluginException；随后 shared_preferences/getAll 报 channel-error。没有卸载、清除应用数据或覆盖安装。
3. 源码：MainActivity 已调用 `super.configureFlutterEngine`，并非漏调用父类注册。主要错误在生成注册内容缺失。
4. 服务器：调查时 `https://47-76-60-77.sslip.io/health` 返回 HTTP 200、`{"status":"ok"}`。这只证明健康端点可达，不代表登录、书籍查询、模型上游和数据完整性全部通过。
5. 本机诊断：固定 SDK 的 Dart 能读取安全存储、扫码、JNI、本地 photo_manager 的 pubspec；直接执行 Flutter `findPlugins`，有无 pubspec cache 均发现 99 个跨平台插件描述。重新执行 `.\flutterw.cmd pub get --offline` 成功，Android 清单恢复为 27 项。
6. 提交检查：`654a5d9` 在 15:05 添加 Gradle 配置阶段对 Flutter 生成 JSON 的覆盖写入，并新增本地 photo_manager override。出问题 APK 的生成时间晚于该提交。当前清单模拟路径替换前后条目数均为 27，因此它是高优先级嫌疑，但不是已证明的直接删项原因。

## 各症状的故障链

| 症状 | 已查明的依赖链 | 判断边界 |
| --- | --- | --- |
| 登录验证失败 | flutter_secure_storage 原生处理器缺失，read 在客户端失败 | 设备日志已复现，不能据此判断验证码错误或登录服务器异常 |
| 侧栏加载失败 | reading_space_sidebar.dart:108 读取书库和历史；database_service.dart:35 先获取文档目录；path_provider_android 2.3.1 使用 JNI；旧 APK 缺 libdartjni.so | 截图、源码及包内容相互吻合；未检查数据库内容，不宣称数据已丢失或完整 |
| 扫码画面关闭 | mobile_scanner 未注册，权限插件亦缺失，原生相机能力无法正常启动 | 高置信同源问题；尚未单独采集扫码页异常日志和相机权限状态 |
| 对话发送失败 | home_page.dart:1825 先验证登录会话；1926 保存历史成功后才启动云端任务 | 登录或本地存储失败可阻断模型调用；按钮置灰另受文本、附件、编辑保存状态控制，尚未证实其具体分支 |
| 更多功能不可用 | 录音、共享偏好、外部分享插件也缺失 | 设备启动日志已证实，故障范围不止四个页面 |

## 已完成与未完成

- 已完成：固定 SDK `flutterw.cmd` 离线重新生成依赖元数据，Android 插件清单恢复为 27 项，包含 secure storage、scanner、JNI、shared preferences、sqflite、record 等插件。
- 已完成：移除了 `android/settings.gradle.kts` 对 Flutter 生成文件的原地文本改写；改为只读解析插件 JSON，并在 Android 插件清单或生成 registrant 缺项时停止构建、列出缺项及修复命令。该检查不改写 Flutter 生成文件。
- 已完成：重新构建 Android arm64 debug 与 profile 包；两者的 Android registrant 均包含 22 个插件，两个 APK 都包含 `libdartjni.so` 和 `libflutter.so`。profile 包另含预期的 `libapp.so`；debug 包没有 AOT `libapp.so` 属正常差异。
- 已完成：将 profile 包用 `adb install -r` 覆盖安装到 TB335FC 平板；未卸载应用、未清除数据。更新后启动进程仍在运行；安装后最近日志未发现 MissingPluginException、JNI 加载失败或应用启动崩溃。没有比对数据库内容，因此不声称业务数据已逐项验收。
- 待用户验收：登录持久化、相机扫码、侧栏书库/历史读取、模型对话和重启后数据保留。此次没有 ARTEMIS 工具，未执行 UI 自动化或逐项业务操作。
- 直接故障仍可归结为旧客户端包原生插件注册与 JNI 库缺失；`654a5d9` 的 Gradle 清单改写是高优先级嫌疑。旧构建时的元数据和 verbose 日志已不可恢复，所以具体是哪一步让清单缩水仍未被复现，不能说唯一触发原因已证明。
- 本次只改 Flutter Android 构建侧，没有改业务 Dart/API、服务端代码或部署配置。当前线上 `/health` 返回 HTTP 200、`{"status":"ok"}`，因此本次不需要服务器部署。
- 版本策略检查另发现：客户端和服务端源码中没有显式的 release ID/API contract version 握手机制。当前修复保留应用版本 `1.0.0+5`，没有引入 API 契约变化；缺失的版本握手是需要两端配套实现的独立待办，本次没有擅自扩展或部署它。
- 其他平台：本次证据仅指向 Android。新增 preflight 只在 Android Gradle 构建时运行；没有证据表明 iOS、Windows、macOS 或 Linux 同样失效，也未对这些平台执行构建/真机验收。

## 完整修复方案

### 1. 固定构建环境并阻断再次漏插件（已完成）

统一使用现有 `flutterw.cmd` 所指定的 Flutter 3.47.5 和 PUB_CACHE。保留现有依赖锁文件，不用升级所有依赖或降级 JNI 来掩盖打包遗漏。

在 Android 构建入口增加了构建前检查：只读解析 `.flutter-plugins-dependencies`，检查项目核心 Android 插件是否存在，并检查 `GeneratedPluginRegistrant.java` 是否包含对应注册项。缺项时停止构建并打印缺项及 `flutterw.cmd pub get` 修复提示，避免生成“编译成功但核心功能全坏”的包。当前检查不验证插件目录实际存在；核心插件基线需要随依赖变更维护。

此前调查保留了当前依赖生成结果并确认固定 SDK 版本为 Flutter 3.47.5。Gradle 不再做路径归一化写回；若将来仍出现清单缩水，应重新采集 `flutter pub get` 与 Gradle 的 verbose 日志。此次没有复现旧清单缩水，因此原始触发点仍未定案。

### 2. 重建并检查包内容（已完成）

使用固定入口重新生成依赖并构建 Android arm64 debug/profile APK。未执行 `flutter clean`，也没有清理全局 Pub 缓存或设备数据。

实际构建命令：

```powershell
.\flutterw.cmd clean
.\flutterw.cmd pub get --offline
.\flutterw.cmd build apk --profile --target-platform android-arm64
```

构建后确认 Android 注册类有 22 个注册项，debug/profile APK 均含 arm64 `libdartjni.so` 与 `libflutter.so`，profile APK 含 `libapp.so`。本次未完成合并 Manifest 的网络/相机权限审计，也没有构建 release APK；这些不影响当前针对 profile 与 debug 的插件注册修复结论。

### 3. 保留数据覆盖安装（已完成）

记录设备包名、应用版本和数据目录后，使用 `adb -s <serial> install -r app-profile.apk` 覆盖安装成功。未卸载、未清除存储、未重建数据库。Android 包管理器接受更新，说明签名兼容；设备数据目录仍为 `/data/user/0/com.example.xiaoqi_app`。

若后续同签名更新失败，应停止并使用匹配签名重建；不能通过卸载绕过。若新包仍出现异常，保留设备数据和日志再定位，不做数据迁移或版本兼容层。

### 4. 真机按依赖顺序验收（待用户完成）

1. 冷启动：无 MissingPluginException、JNI dlopen 失败、shared_preferences channel-error；本地历史和书库可读。
2. 登录：用户完成邮箱验证；会话写入安全存储成功；重启后仍保留登录。验证码不记录到诊断文档。
3. 扫码：检查相机权限；出现真实预览；有效 ISBN 可识别并查询；拒绝权限、返回与重入有明确反馈。
4. 对话：输入文字后检查按钮状态；点击后确认用户消息持久化、云端任务发起、模型响应和历史再次打开成功；失败后能够重试。
5. 回归：侧栏书库/历史、录音、外部分享和偏好恢复；比较修复前后已有数据，用户完成关键体验验收。

如原生依赖恢复后仍有发送按钮问题，再按输入内容、isSavingMessageEdit、isPreparingToSend、登录校验逐项定位，不能先把按钮强行 enabled 或跳过会话/持久化检查。

### 5. 验收与回退标准

分别记录：构建前检查通过、profile 编译通过、APK 原生内容通过、覆盖安装成功、冷启动通过、各业务闭环通过、既有数据确认。前一项不能替代后一项。

本次不需要服务器发布，线上健康端点为 HTTP 200。若后续发现确需修改服务代码或 API 合同，则按项目规定同步两端版本并执行 `deploy_current.ps1`，在健康和数据检查失败时自动回退。

## 官方参考

- Flutter 官方插件使用说明：平台原生代码必须随应用构建，hot reload/hot restart 不能补齐原生插件，需要完整重启构建后的应用。https://docs.flutter.dev/packages-and-plugins/using-packages
- Flutter 官方 MissingPluginException API。https://api.flutter.dev/flutter/services/MissingPluginException-class.html
- 本地 Flutter 工具源码用于直接诊断；未直接复制或修改上游实现，文件注明 BSD-style license。

## 交付边界

本次已交付 Android 构建防护、debug/profile 包和平板 profile 覆盖安装；视频未逐帧分析，已用截图、源码、包内容与实时设备日志定位。安装后的自动化/完整业务闭环尚待用户真机确认。ARTEMIS 工具未提供，未执行其设备工作流。

server deployment not needed：未更改服务端代码、部署配置或 API 合同；本次证实的缺陷在客户端原生插件生成与打包。
