pluginManagement {
    // Flutter 3.47.5 double-escapes Windows plugin paths in this generated JSON.
    // Normalize it before the Flutter plugin loader resolves the native folders.
    val flutterPluginDependencies = java.io.File(
        settingsDir.parentFile,
        ".flutter-plugins-dependencies",
    )
    if (flutterPluginDependencies.isFile) {
        val content = flutterPluginDependencies.readText()
        val normalized = content.replace("\\".repeat(4), "\\".repeat(2))
        if (normalized != content) {
            flutterPluginDependencies.writeText(normalized)
        }
    }

    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        maven("https://maven.aliyun.com/repository/google")
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.2.1" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
