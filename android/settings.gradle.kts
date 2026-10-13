pluginManagement {
    val flutterPluginDependencies = java.io.File(
        settingsDir.parentFile,
        ".flutter-plugins-dependencies",
    )
    if (!flutterPluginDependencies.isFile) {
        throw GradleException("Flutter plugin metadata is missing. Run .\\flutterw.cmd pub get, then rebuild.")
    }

    val metadata = groovy.json.JsonSlurper().parseText(flutterPluginDependencies.readText()) as? Map<*, *>
        ?: throw GradleException("Flutter plugin metadata is invalid. Run .\\flutterw.cmd pub get, then rebuild.")
    val pluginPlatforms = metadata["plugins"] as? Map<*, *>
        ?: throw GradleException("Flutter plugin metadata has no plugin list. Run .\\flutterw.cmd pub get, then rebuild.")
    val androidPlugins = pluginPlatforms["android"] as? List<*>
        ?: throw GradleException("Flutter Android plugin list is missing. Run .\\flutterw.cmd pub get, then rebuild.")
    val androidPluginNames = androidPlugins.mapNotNull { (it as? Map<*, *>)?.get("name") as? String }.toSet()
    val requiredAndroidPlugins = setOf(
        "android_file_picker",
        "flutter_secure_storage",
        "jni",
        "jni_flutter",
        "mobile_scanner",
        "path_provider_android",
        "permission_handler_android",
        "photo_manager",
        "receive_sharing_intent",
        "record_android",
        "shared_preferences_android",
        "sqflite_android",
    )
    val missingAndroidPlugins = requiredAndroidPlugins - androidPluginNames
    if (missingAndroidPlugins.isNotEmpty()) {
        throw GradleException(
            "Required Flutter Android plugins are missing: ${missingAndroidPlugins.sorted().joinToString()}. " +
                "Run .\\flutterw.cmd pub get, then rebuild.",
        )
    }

    val registrant = java.io.File(
        settingsDir,
        "app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
    )
    if (!registrant.isFile) {
        throw GradleException("Flutter Android plugin registrant is missing. Run .\\flutterw.cmd pub get, then rebuild.")
    }
    val requiredRegistrantClasses = mapOf(
        "android_file_picker" to "FilePickerPlugin",
        "flutter_secure_storage" to "FlutterSecureStoragePlugin",
        "jni" to "JniPlugin",
        "jni_flutter" to "JniFlutterPlugin",
        "mobile_scanner" to "MobileScannerPlugin",
        "permission_handler_android" to "PermissionHandlerPlugin",
        "photo_manager" to "PhotoManagerPlugin",
        "receive_sharing_intent" to "ReceiveSharingIntentPlugin",
        "record_android" to "RecordPlugin",
        "shared_preferences_android" to "SharedPreferencesPlugin",
        "sqflite_android" to "SqflitePlugin",
    )
    val registeredPluginClasses = registrant.readLines()
        .filter { it.contains("flutterEngine.getPlugins().add(new ") }
        .map { it.substringAfter("add(new ").substringBefore("()").substringAfterLast(".") }
        .toSet()
    val missingRegistrations = requiredRegistrantClasses.filterValues { it !in registeredPluginClasses }.keys
    if (missingRegistrations.isNotEmpty()) {
        throw GradleException(
            "Required Flutter Android plugin registrations are missing: ${missingRegistrations.sorted().joinToString()}. " +
                "Run .\\flutterw.cmd pub get, then rebuild.",
        )
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
