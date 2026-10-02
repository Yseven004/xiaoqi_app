import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localRuntimeConfig = Properties().apply {
    val configFile = rootProject.file("../private/models.local.env")
    if (configFile.isFile) {
        configFile.inputStream().use(::load)
    }
}

fun localConfigString(name: String): String {
    val value = localRuntimeConfig.getProperty(name, "")
        .replace("\\", "\\\\")
        .replace("\"", "\\\"")
    return "\"$value\""
}

android {
    namespace = "com.example.xiaoqi_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.xiaoqi_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        buildConfigField("String", "XIAOQI_HOME_CHAT_DEEPSEEK_API_KEY", localConfigString("DEEPSEEK_API_KEY"))
        buildConfigField("String", "XIAOQI_HOME_CHAT_MIMO_API_KEY", localConfigString("MIMO_API_KEY"))
        buildConfigField("String", "XIAOQI_TANSHU_PROXY_TOKEN", localConfigString("TANSHU_PROXY_TOKEN"))
        buildConfigField("String", "XIAOQI_TANSHU_PROXY_ENDPOINT", localConfigString("TANSHU_PROXY_ENDPOINT"))
        buildConfigField("String", "XIAOQI_VLM_API_KEY", localConfigString("VLM_API_KEY"))
        buildConfigField("String", "XIAOQI_DEEPSEEK_API_KEY", localConfigString("DEEPSEEK_API_KEY"))
        buildConfigField("String", "XIAOQI_DEEPSEEK_MODEL", localConfigString("DEEPSEEK_MODEL"))
        buildConfigField("String", "XIAOQI_BOOK_GLM_API_KEY", localConfigString("BOOK_GLM_API_KEY"))
        buildConfigField("String", "XIAOQI_BOOK_GLM_MODEL", localConfigString("BOOK_GLM_MODEL"))
        buildConfigField("String", "XIAOQI_WEREAD_API_KEY", localConfigString("WEREAD_API_KEY"))
        buildConfigField("String", "XIAOQI_GOOGLE_BOOKS_API_KEY", localConfigString("GOOGLE_BOOKS_API_KEY"))
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
