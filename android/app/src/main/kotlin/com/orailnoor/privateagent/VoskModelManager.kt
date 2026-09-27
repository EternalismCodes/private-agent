package com.orailnoor.privateagent

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Downloads and unpacks the small Vosk English model once, the first time
 * the wake word is turned on. After that everything runs fully offline —
 * this is a one-time ~40MB fetch, not something that happens per listen.
 */
object VoskModelManager {
    private const val MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
    private const val MODEL_DIR_NAME = "vosk-model-small-en-us-0.15"

    fun modelDir(context: Context): File = File(context.filesDir, MODEL_DIR_NAME)

    fun isReady(context: Context): Boolean {
        val dir = modelDir(context)
        return dir.exists() && File(dir, "conf").exists()
    }

    /** Blocking — call from a background thread. [onProgress] gets 0..100, or -1 if size is unknown. */
    fun ensureModel(context: Context, onProgress: (Int) -> Unit): Boolean {
        if (isReady(context)) return true
        val zipFile = File(context.cacheDir, "vosk-model.zip")
        try {
            val conn = URL(MODEL_URL).openConnection() as HttpURLConnection
            conn.connect()
            val total = conn.contentLength
            conn.inputStream.use { input ->
                FileOutputStream(zipFile).use { out ->
                    val buf = ByteArray(64 * 1024)
                    var read: Int
                    var downloaded = 0L
                    while (input.read(buf).also { read = it } != -1) {
                        out.write(buf, 0, read)
                        downloaded += read
                        onProgress(if (total > 0) ((downloaded * 100) / total).toInt() else -1)
                    }
                }
            }
            unzip(zipFile, context.filesDir)
            zipFile.delete()
            return isReady(context)
        } catch (e: Exception) {
            zipFile.delete()
            return false
        }
    }

    private fun unzip(zipFile: File, destDir: File) {
        ZipInputStream(zipFile.inputStream()).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val outFile = File(destDir, entry.name)
                if (entry.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos ->
                        val buf = ByteArray(64 * 1024)
                        var read: Int
                        while (zis.read(buf).also { read = it } != -1) fos.write(buf, 0, read)
                    }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
    }
}
