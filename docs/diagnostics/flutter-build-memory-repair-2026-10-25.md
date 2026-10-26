# Flutter Android 构建内存故障修复

日期：2026-10-25。用户授权修复 flutter run，并在解释后明确授权 Windows 分页文件改为自动管理；没有授权自动重启、安装或操作真机。

## 已确认的原因

- 用户失败日志：Gradle 9.4.1 daemon 27268 消失；`android/hs_err_pid27268.log` 明确报告 native malloc 无法分配约 1.6 MB，不是 Dart 编译语法报错。
- 机器物理内存约 16 GB，当前总提交容量约 17.7 GiB；`Win32_PageFileUsage` 实际仅报告 C 盘 2048 MB。配置中虽有 D 盘 16–32 GB，当前使用记录与提交总量没有体现它，不能把该配置当成有效容量。
- 项目 Gradle daemon 原配置最大堆 2 GB；Windows wrapper 的 `DEFAULT_JVM_OPTS` 为空，客户端也产生了额外 JVM 开销。重编译中还出现 Dart 无法启动 worker 线程，说明仅重试 daemon 不能解决系统提交容量不足。

## 持久修复

- `android/gradle.properties`：daemon 最大堆 1 GB、元空间 512 MB、代码缓存 128 MB，2 个可见处理器，Serial GC；保留单 worker 与 Kotlin 进程内编译，明确禁用 Gradle 并行任务。完成构建后空闲 60 秒退出，避免默认长期保留构建 JVM。
- `android/gradlew.bat`：Windows 启动客户端固定 64 MB 堆和 2 个可见处理器，使用 Serial GC。普通 `flutter run` 会自动经过这两个文件，无需每次手动传递临时参数。
- 用户明确同意后，通过 Windows UAC 执行仅修改 `AutomaticManagedPagefile` 的本机脚本，已读回 `true`。前后记录位于 `.codex-artifacts/build-repair-2026-10-25/pagefile-before.json` 与 `pagefile-setting-result.json`。未关闭用户应用、修改 SDK/Pub 缓存、删除数据或重启系统。新分页容量仍待用户重启后核实。

## 验证记录

- 定向 `flutter analyze --no-pub`：三个相关 Dart 文件没有 error 级诊断；仍有 89 条 lint/info/warning，因此不能称为整个静态检查全绿。
- 第一次调试构建：Dart worker 线程因资源不足退出，未完成。
- 全架构重试：Gradle 未重现原 native memory 崩溃，但 `pdfium_dart 0.2.5` 的 Android arm（32 位）PDFium GitHub 下载超时，打包失败。没有为此更换依赖版本或删除 ABI 支持。
- Android arm64 调试构建：`flutter build apk --debug --no-pub --target-platform android-arm64` 返回码 0，已生成 `build/app/outputs/flutter-apk/app-debug.apk`。完整日志保存在 `.codex-artifacts/build-repair-2026-10-25/build-apk-arm64.log`。该结果确认 64 位客户端编译与打包成功，不代表 32 位依赖下载或真机启动通过。
- 真机启动及 UI 验收：未执行。
- 成功打包后通过项目 wrapper 的 `--stop` 正常退出本次唯一 Gradle daemon，释放验证进程；后续新启动的 daemon 采用 60 秒空闲退出规则。

## 参考与边界

- [Gradle JVM 配置说明](https://docs.gradle.org/current/userguide/config_gradle.html)、[JDK 21 java 参数说明](https://docs.oracle.com/en/java/javase/21/docs/specs/man/java.html)，查阅于 2026-10-25。仅参考公开配置接口，无外部实现代码复制或新增依赖。
- 低内存构建配置可能降低构建速度；不保证其他应用耗尽系统资源时仍可构建。系统分页容量和目标平台编译成功需要分别记录，不以设置成功冒充实际运行成功。
- server deployment not needed：仅 Android 本机构建配置与经用户批准的 Windows 内存设置，无服务端/API 改动。
