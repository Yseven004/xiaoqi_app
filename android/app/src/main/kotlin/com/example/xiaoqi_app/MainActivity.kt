package com.example.xiaoqi_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "xiaoqi_app/runtime_config",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWereadApiKey" -> result.success(BuildConfig.XIAOQI_WEREAD_API_KEY)
                "getGoogleBooksApiKey" -> result.success(BuildConfig.XIAOQI_GOOGLE_BOOKS_API_KEY)
                "getTanshuProxyToken" -> result.success(BuildConfig.XIAOQI_TANSHU_PROXY_TOKEN)
                "getTanshuProxyEndpoint" -> result.success(BuildConfig.XIAOQI_TANSHU_PROXY_ENDPOINT)
                "getDeepSeekModel" -> result.success(BuildConfig.XIAOQI_DEEPSEEK_MODEL)
                "getVlmApiKey" -> result.success(BuildConfig.XIAOQI_VLM_API_KEY)
                "getBookGlmApiKey" -> result.success(BuildConfig.XIAOQI_BOOK_GLM_API_KEY)
                "getDeepSeekApiKey" -> result.success(BuildConfig.XIAOQI_DEEPSEEK_API_KEY)
                "getBookGlmModel" -> result.success(BuildConfig.XIAOQI_BOOK_GLM_MODEL)
                "getHomeChatApiKey" -> {
                    val key = when (call.argument<String>("provider")?.lowercase()) {
                        "deepseek" -> BuildConfig.XIAOQI_HOME_CHAT_DEEPSEEK_API_KEY
                        "mimo" -> BuildConfig.XIAOQI_HOME_CHAT_MIMO_API_KEY
                        else -> null
                    }
                    if (key == null) {
                        result.error(
                            "unsupported_provider",
                            "Unsupported home chat provider.",
                            null,
                        )
                    } else {
                        result.success(key)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
