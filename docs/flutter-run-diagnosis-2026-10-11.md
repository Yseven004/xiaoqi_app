# flutter run 根因与解决方案

## 根因

系统 PATH 指向 `C:\flutter\bin`，对应 Flutter 3.41.9 / Dart 3.11.5。项目 `pubspec.yaml` 要求 Dart `^3.12.0`，锁文件要求 Flutter `>=3.44.0`，因此旧 SDK 必然在依赖解析时失败。

本机已安装 `C:\Users\20833\develop\flutter-3.47.5\flutter`，对应 Flutter 3.47.5 / Dart 3.13.4；项目原有 package_config 也是由该版本生成。PowerShell profile 定义了按项目目录切换 SDK 的 flutter/dart 函数，但截图中的执行策略阻止 profile 加载，导致调用旧 SDK。首次设备选择输入 q 是主动退出，不是编译错误。

SDK 切换后出现了第二个、独立的 Android 构建阻塞：Gradle JVM 原来配置 `-Xmx8G -XX:MaxMetaspaceSize=4G`；Windows 页面文件被固定为 4 GB，自动管理关闭。JVM 崩溃报告记录了 metaspace/native 内存提交失败，首次崩溃时系统可用提交空间仅 47 MB。Flutter 输出的 Gradle 8.14、AGP 8.11.1 和 Kotlin 2.2.20 信息是将来兼容性警告，不是这次 daemon crash 的直接原因。

重启并应用系统管理页面文件后，第一次完整构建暴露出第三个独立阻塞：项目在 `C:`，`PUB_CACHE` 原先在 `D:\dev\pub-cache`。Kotlin 增量编译在关闭缓存时报告 `this and base files have different roots`，涉及 `file_picker` 等插件。根因是 Kotlin 将插件源码路径相对项目路径归档时跨越 Windows 卷根。

## 已落实

- 新增根目录 `flutterw.cmd`，直接调用上述固定 SDK，透传参数和退出码，不依赖 PowerShell profile 或全局 PATH。
- 新增 `.vscode/settings.json`，让 VS Code / 兼容编辑器的 Dart 插件选择相同 SDK。
- `android/gradle.properties` 将 Gradle JVM 上限收至 3 GB heap、1 GB metaspace，并将并行 worker 限制为 2，避免原先配置的 8 GB heap 继续挤压系统提交空间。
- Windows 页面文件现由系统管理；重启后实际提交上限为 27.2 GB，构建期间可用提交空间保持在 6 GB 以上，没有再次发生 JVM native-memory OOM。
- 建立目录联接 `C:\Users\20833\AppData\Local\Pub\CacheD` → `D:\dev\pub-cache`。缓存数据仍实际存放在 D 盘；项目的两个 PowerShell profile 和 `flutterw.cmd` 仅在此项目运行时设置 `PUB_CACHE` 为 C 盘联接路径。
- `flutter pub get` 已重新生成 `.dart_tool/package_config.json`；其中包目录均指向 C 盘联接入口，指向旧 D 盘字面路径的包数为 0。
- 未降低项目 SDK 约束，未升级依赖，未更改全局旧 SDK。
- CurrentUser 执行策略为 RemoteSigned；新启动的 Windows PowerShell 能加载 profile，并在项目目录选择 Flutter 3.47.5 和 C 盘 Pub 联接入口。编辑 profile 后，已打开的旧终端要重载一次 profile 或关闭后重开。

## 推荐启动方式

在 Codex PowerShell 侧边栏终端的项目目录执行（重载 profile 后可直接使用标准命令）：

```powershell
flutter --version
flutter pub get
flutter devices
flutter run -d <devices列出的Android设备ID>
flutter run --profile -d <devices列出的Android设备ID>
```

当前 shell 若仍保留旧 profile 函数，先执行一次 `. "$HOME\Documents\WindowsPowerShell\profile.ps1"`，或关闭并重新打开 Codex 终端。只有一台目标移动设备时也可以省略 `-d` 并按提示选择。无线设备 ID 可能变化，以实际 `flutter devices` 输出为准。`flutterw.cmd` 仍可作为不依赖 profile 的备用入口。

## 其他环境问题

- 截图当时只有 Windows / Edge，表示当时没有被 Flutter 发现的 Android 设备；本次 doctor 已发现 TB335FC Android 16 无线设备。
- Android 部分许可证未接受。若构建提示许可证错误，由用户执行 `.\flutterw.cmd doctor --android-licenses` 阅读并接受所需条款。
- Windows 桌面缺 Visual Studio C++ 工具链。仅在需要运行 Windows 桌面版时安装 Visual Studio 的 Desktop development with C++ 工作负载；Android 开发不因此受阻。
- Chrome 路径无效，属于 Chrome Web 目标的问题，不是本次 Dart SDK 解析失败的原因。

## 验证边界

- 新开 Windows PowerShell 的 `flutter --version`：通过，3.47.5 / Dart 3.13.4。
- `flutter pub get`：通过，退出码 0；`.dart_tool/package_config.json` 只记录 C 盘联接路径。
- `flutter run -d adb-HA2FXQ2J-fWvoX7._adb-tls-connect._tcp`：通过，debug APK 406 MB 构建并安装到 TB335FC，Flutter 引擎启动且数据库初始化日志正常。
- `flutter run --profile -d adb-HA2FXQ2J-fWvoX7._adb-tls-connect._tcp`：通过，profile APK 327.7 MB 构建并安装；设备 VM Service 可连接，语音模型初始化完成。
- Android 构建仍会提示 Gradle 8.14、AGP 8.11.1、Kotlin 2.2.20 将来会退出 Flutter 支持范围，并提示 Java 8 source/target 过时；本次 debug/profile 构建均成功。这些升级属于后续维护，不是当前运行的必要条件。

## 官方依据

- Flutter SDK 与其内置 Dart 的对应关系：https://docs.flutter.dev/install/archive
- Flutter 安装与 PATH：https://docs.flutter.dev/install/manual
- PowerShell 执行策略与作用域：https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1
- Pub cache 环境变量：https://dart.dev/tools/pub/environment-variables
- Kotlin Gradle 插件增量编译与缓存：https://kotlinlang.org/docs/gradle-compilation-and-caches.html
