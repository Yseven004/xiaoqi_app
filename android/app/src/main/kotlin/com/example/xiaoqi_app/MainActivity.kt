package com.example.xiaoqi_app

import android.annotation.TargetApi
import android.os.Build
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.widget.FrameLayout
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var annotationEditorBack: (() -> Unit)? = null
    private var unregisterAnnotationEditorBack: (() -> Unit)? = null

    override fun setContentView(view: View) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            super.setContentView(view)
            return
        }
        // Older Android versions dispatch BACK to the focused hierarchy before the IME.
        val content = object : FrameLayout(this) {
            private var trackingBack = false

            override fun dispatchKeyEventPreIme(event: KeyEvent): Boolean {
                if (event.keyCode == KeyEvent.KEYCODE_BACK) {
                    if (event.action == KeyEvent.ACTION_DOWN && annotationEditorBack != null) {
                        trackingBack = true
                        return true
                    }
                    if (event.action == KeyEvent.ACTION_UP && trackingBack) {
                        trackingBack = false
                        if (!event.isCanceled) annotationEditorBack?.invoke()
                        return true
                    }
                }
                return super.dispatchKeyEventPreIme(event)
            }
        }
        content.addView(view, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        super.setContentView(content)
    }

    private fun setAnnotationEditorBack(callback: (() -> Unit)?) {
        if ((annotationEditorBack == null) == (callback == null)) return
        annotationEditorBack = callback
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            unregisterAnnotationEditorBack?.invoke()
            unregisterAnnotationEditorBack = callback?.let(::registerAnnotationEditorBack)
        }
    }

    @TargetApi(Build.VERSION_CODES.TIRAMISU)
    private fun registerAnnotationEditorBack(callback: () -> Unit): () -> Unit {
        val dispatcher = onBackInvokedDispatcher
        val invoked = OnBackInvokedCallback {
            if (annotationEditorBack === callback) callback()
        }
        dispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_OVERLAY, invoked)
        return { dispatcher.unregisterOnBackInvokedCallback(invoked) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        setAnnotationEditorBack(null)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(FastOcrChannel())

        val bookDownloads = BookDownloads(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "xiaoqi_app/book_downloads",
        ).setMethodCallHandler { call, result ->
            if (call.method == "saveVerifiedBook") bookDownloads.save(call, result)
            else result.notImplemented()
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "xiaoqi_app/runtime_config",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setAnnotationEditorBackEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    setAnnotationEditorBack(
                        if (enabled) flutterEngine.navigationChannel::popRoute else null,
                    )
                    result.success(null)
                }
                "setCompanionBrightness" -> {
                    val brightness = call.argument<Double>("brightness")
                    val attributes = window.attributes
                    attributes.screenBrightness = brightness?.coerceIn(0.05, 1.0)?.toFloat() ?: -1f
                    window.attributes = attributes
                    result.success(null)
                }
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
