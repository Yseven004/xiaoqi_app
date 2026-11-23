package com.example.xiaoqi_app

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/** Publishes only verified book files; work stays off the platform UI thread. */
class BookDownloads(private val context: Context) {
    fun save(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val displayName = call.argument<String>("displayName")
        val format = call.argument<String>("format")
        val hash = call.argument<String>("sha256")
        if (sourcePath == null || displayName == null ||
            format !in setOf("pdf", "epub") || hash?.matches(Regex("[a-f0-9]{64}")) != true
        ) {
            result.error("invalid_book", "下载文件信息无效", null)
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("downloads_not_supported", "自动保存到系统下载目录需要 Android 10 或更高版本", null)
            return
        }
        worker.execute {
            try {
                val uri = publish(File(sourcePath), displayName, format!!, hash)
                main.post { result.success(uri.toString()) }
            } catch (error: Exception) {
                main.post { result.error("save_download_failed", "保存到系统下载目录失败，请重试", null) }
            }
        }
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun publish(source: File, displayName: String, format: String, hash: String): Uri {
        val file = source.canonicalFile
        // The channel accepts only the app's verified private copy, never arbitrary paths.
        require(file.path.startsWith(context.dataDir.canonicalPath + File.separator))
        require(file.isFile && file.length() in 129..(256L * 1024 * 1024))
        val expectedLength = file.length()
        val resolver = context.contentResolver
        val saved = context.getSharedPreferences("book_downloads", Context.MODE_PRIVATE)
        val key = "$hash.$format"
        val previous = saved.getString(key, null)
        if (previous != null) {
            try {
                val uri = Uri.parse(previous)
                if (uri.scheme == "content" && uri.authority == MediaStore.AUTHORITY &&
                    resolver.query(uri, arrayOf(MediaStore.Downloads.RELATIVE_PATH), null, null, null)?.use { cursor ->
                        cursor.moveToFirst() && cursor.getString(0)?.trimEnd('/') == "${Environment.DIRECTORY_DOWNLOADS}/小栖"
                    } == true &&
                    resolver.openInputStream(uri)?.use { stream ->
                        val digest = MessageDigest.getInstance("SHA-256")
                        val buffer = ByteArray(64 * 1024)
                        var count = 0L
                        var size = stream.read(buffer)
                        while (size >= 0) {
                            count += size
                            if (count > expectedLength) return@use false
                            digest.update(buffer, 0, size)
                            size = stream.read(buffer)
                        }
                        count == expectedLength && digest.digest().hex() == hash
                    } == true
                ) return uri
            } catch (_: Exception) {
                // Deleted or changed public files are safely recreated on an explicit retry.
            }
            saved.edit().remove(key).apply()
        }
        val name = safeName(displayName, format)
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, if (format == "pdf") "application/pdf" else "application/epub+zip")
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/小栖")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = checkNotNull(resolver.insert(
            MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values,
        ))
        var published = false
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            var copied = 0L
            checkNotNull(resolver.openOutputStream(uri, "w")).use { output ->
                file.inputStream().use { input ->
                    val buffer = ByteArray(64 * 1024)
                    var size = input.read(buffer)
                    while (size >= 0) {
                        copied += size
                        check(copied <= expectedLength)
                        digest.update(buffer, 0, size)
                        output.write(buffer, 0, size)
                        size = input.read(buffer)
                    }
                }
                output.flush()
            }
            check(copied == expectedLength && digest.digest().hex() == hash)
            check(resolver.update(uri, ContentValues().apply {
                put(MediaStore.Downloads.IS_PENDING, 0)
            }, null, null) == 1)
            published = true
            saved.edit().putString(key, uri.toString()).commit()
            return uri
        } finally {
            if (!published) resolver.delete(uri, null, null)
        }
    }

    private fun safeName(name: String, format: String): String {
        var stem = name.trim()
        if (stem.endsWith(".$format", ignoreCase = true)) stem = stem.dropLast(format.length + 1)
        stem = stem.replace(Regex("[\\x00-\\x1f\\x7f/\\\\:*?\"<>|]"), "_").trim('.', ' ')
        val limited = StringBuilder()
        var bytes = 0
        val points = stem.codePoints().iterator()
        while (points.hasNext()) {
            val character = String(Character.toChars(points.nextInt()))
            bytes += character.toByteArray(Charsets.UTF_8).size
            if (bytes > 180) break
            limited.append(character)
        }
        stem = limited.toString().trim('.', ' ')
        if (stem.isEmpty()) stem = "电子书"
        return "$stem.$format"
    }

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 0xff) }

    companion object {
        private val worker = Executors.newSingleThreadExecutor()
        private val main = Handler(Looper.getMainLooper())
    }
}
