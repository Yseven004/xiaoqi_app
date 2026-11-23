package com.example.xiaoqi_app

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.googlecode.tesseract.android.TessBaseAPI
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors

/** Recognizes PDF and document images entirely on the device. */
class FastOcrChannel : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var worker: OcrWorker? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        worker = OcrWorker(binding.applicationContext)
        channel = MethodChannel(binding.binaryMessenger, "xiaoqi_app/fast_ocr").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        worker?.close()
        worker = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recognizeChineseText", "recognizePage" -> {
                val path = call.argument<String>("imagePath")
                if (path.isNullOrBlank()) {
                    result.error("invalid_image", "未指定待识别的图片", null)
                    return
                }
                val requested = if (call.method == "recognizeChineseText") {
                    listOf("zh-Hans", "en")
                } else {
                    call.argument<List<String>>("languages").orEmpty().ifEmpty {
                        MODELS.keys.toList()
                    }
                }
                val unsupported = requested.filterNot(MODELS::containsKey).distinct()
                val models = requested.mapNotNull(MODELS::get).distinct()
                if (models.isEmpty()) {
                    result.error("unsupported_language", "本机 OCR 暂不支持：${unsupported.joinToString()}", null)
                    return
                }
                worker?.recognize(path, models, unsupported, call.argument<String>("jobId"), result)
                    ?: result.error("unavailable", "本机 OCR 不可用", null)
            }
            "cancelRecognition" -> {
                val jobId = call.argument<String>("jobId")
                if (jobId != null) worker?.cancel(jobId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private companion object {
        val MODELS = mapOf("zh-Hans" to "chi_sim", "zh-Hant" to "chi_tra", "en" to "eng", "ja" to "jpn")
    }
}

private class OcrWorker(private val context: Context) {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val jobs = mutableSetOf<OcrJob>()
    private var closed = false

    // Only the executor reads or replaces the engine and the models it has loaded.
    private var engine: TessBaseAPI? = null
    private var loadedModels: List<String>? = null
    private var activeRecognition: OcrJob? = null

    fun recognize(
        path: String,
        models: List<String>,
        unsupported: List<String>,
        jobId: String?,
        result: MethodChannel.Result,
    ) {
        val job = OcrJob(jobId)
        jobs.add(job)
        executor.execute {
            try {
                val payload = readPage(path, models, unsupported, job)
                finish(job, result) { result.success(payload) }
            } catch (error: IOException) {
                finish(job, result) { result.error("ocr_io", error.message, null) }
            } catch (error: RuntimeException) {
                finish(job, result) { result.error("ocr_failed", error.message ?: "本机文字识别失败", null) }
            } catch (_: LinkageError) {
                finish(job, result) { result.error("unavailable", "当前设备无法载入本机 OCR 引擎", null) }
            }
        }
    }

    private fun finish(job: OcrJob, result: MethodChannel.Result, complete: () -> Unit) {
        main.post {
            jobs.remove(job)
            if (closed) return@post
            if (job.cancelled) {
                result.error("cancelled", "本机文字识别已停止", null)
            } else {
                complete()
            }
        }
    }

    fun cancel(jobId: String) {
        jobs.filter { it.id == jobId }.forEach(OcrJob::cancel)
    }

    fun close() {
        closed = true
        jobs.forEach(OcrJob::cancel)
        jobs.clear()
        executor.execute { engine?.recycle() }
        executor.shutdown()
    }

    private fun engineFor(models: List<String>): TessBaseAPI {
        val current = engine
        if (current != null && loadedModels == models) return current

        val dataDir = context.getDir("local_ocr_4_1_0", Context.MODE_PRIVATE)
        val modelsDir = File(dataDir, "tessdata")
        if (!modelsDir.isDirectory && !modelsDir.mkdirs() && !modelsDir.isDirectory) {
            throw IOException("无法准备本机 OCR 模型目录")
        }
        for (model in models) {
            val name = "$model.traineddata"
            val installed = File(modelsDir, name)
            if (installed.length() > 0) continue
            val temporary = File.createTempFile(name, ".tmp", modelsDir)
            try {
                context.assets.open("local_ocr/tessdata/$name").use { input ->
                    temporary.outputStream().use { output -> input.copyTo(output) }
                }
                if (!temporary.renameTo(installed)) throw IOException("无法准备本机 OCR 模型")
            } finally {
                temporary.delete()
            }
        }

        current?.recycle()
        engine = null
        loadedModels = null
        val next = TessBaseAPI {
            // Stop from Tesseract's progress callback on the same worker thread.
            if (activeRecognition?.cancelled == true) engine?.stop()
        }
        try {
            if (!next.init(dataDir.absolutePath, models.joinToString("+"), TessBaseAPI.OEM_LSTM_ONLY)) {
                throw IOException("无法打开本机 OCR 模型")
            }
            next.setPageSegMode(TessBaseAPI.PageSegMode.PSM_AUTO)
        } catch (error: Exception) {
            next.recycle()
            throw error
        }
        engine = next
        loadedModels = models
        return next
    }

    private fun readPage(
        path: String,
        models: List<String>,
        unsupported: List<String>,
        job: OcrJob,
    ): Map<String, Any> {
        job.checkActive()
        val started = SystemClock.elapsedRealtime()
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw IOException("无法打开待识别的图片")

        val recognizer = engineFor(models)
        job.checkActive()
        val blocks: List<Map<String, Any>>
        try {
            recognizer.setImage(File(path))
            job.checkActive()
            activeRecognition = job
            // Tesseract4Android exposes cancellation through its hOCR entry point.
            // The iterator reads the resulting line geometry without parsing the markup.
            recognizer.getHOCRText(0)
            job.checkActive()
            blocks = readBlocks(recognizer, job)
        } finally {
            activeRecognition = null
            recognizer.clear()
        }

        return mapOf(
            "fullText" to blocks.joinToString("\n\n") { it["text"] as String },
            "blocks" to blocks,
            "imageWidth" to bounds.outWidth,
            "imageHeight" to bounds.outHeight,
            "elapsedMs" to (SystemClock.elapsedRealtime() - started),
            "appliedRotation" to 0,
            "unsupportedLanguages" to unsupported,
        )
    }

    private fun readBlocks(recognizer: TessBaseAPI, job: OcrJob): List<Map<String, Any>> {
        val iterator = recognizer.resultIterator ?: return emptyList()
        val blocks = mutableListOf<Map<String, Any>>()
        val lines = mutableListOf<Map<String, Any>>()
        val blockBounds = Rect()

        fun emitParagraph() {
            if (lines.isEmpty()) return
            blocks.add(
                coordinates(blockBounds) + mapOf(
                    "text" to lines.joinToString("\n") { it["text"] as String },
                    "lines" to lines.toList(),
                ),
            )
            lines.clear()
            blockBounds.setEmpty()
        }

        try {
            iterator.begin()
            val level = TessBaseAPI.PageIteratorLevel.RIL_TEXTLINE
            do {
                job.checkActive()
                if (iterator.isAtBeginningOf(TessBaseAPI.PageIteratorLevel.RIL_PARA)) {
                    emitParagraph()
                }
                val text = iterator.getUTF8Text(level)?.trim().orEmpty()
                val bounds = iterator.getBoundingRect(level)
                if (text.isNotEmpty() && bounds != null && !bounds.isEmpty) {
                    blockBounds.union(bounds)
                    lines.add(
                        coordinates(bounds) + mapOf(
                            "text" to text,
                            "confidence" to (iterator.confidence(level) / 100.0).coerceIn(0.0, 1.0),
                            "angle" to 0.0,
                        ),
                    )
                }
            } while (iterator.next(level))
            emitParagraph()
        } finally {
            iterator.delete()
        }
        return blocks
    }

    private fun coordinates(bounds: Rect) = mapOf(
        "left" to bounds.left,
        "top" to bounds.top,
        "right" to bounds.right,
        "bottom" to bounds.bottom,
    )
}

private class OcrJob(val id: String?) {
    @Volatile
    var cancelled = false
        private set
    fun checkActive() {
        if (cancelled) throw IOException("本机文字识别已停止")
    }

    fun cancel() {
        cancelled = true
    }
}
